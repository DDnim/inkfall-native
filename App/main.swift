import AppKit
import ApplicationServices
import SwiftUI
import InkfallCore

/// 菜单栏常驻宿主。
///
/// 刻意用 AppKit 做宿主而不是纯 SwiftUI `App`：重写需要精确控制窗口层级、
/// 非激活 NSPanel、click-through、`orderFrontRegardless` —— 这些
/// `WindowGroup` 都表达不了。视图内部全用 SwiftUI。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private let permissions = PermissionCoordinator()
    private let store = SettingsStore()
    private let recorder = AudioRecorder()
    private let notch = NotchOverlayController()
    private let noteStore = NoteStore()
    private lazy var noteSession = NoteSessionController(
        recorder: recorder, transcriber: transcriber, store: store, notes: noteStore)
    private lazy var notePanel = NotePanelController(session: noteSession)
    private lazy var models = ModelCatalog(store: store, transcriber: transcriber)
    /// 关键词待命。**是 filter 不是 sink** —— 它和落笔可以同时开。
    private lazy var jarvis = JarvisController(
        recorder: recorder, transcriber: transcriber, store: store, notch: notch)
    /// 本地集成：127.0.0.1:48765 上的 `/api/notes` + `/debug/*`。
    private lazy var integration = IntegrationAPI(
        store: store, notes: noteStore, session: noteSession, jarvis: jarvis,
        notch: notch, permissions: permissions)
    private var httpServer: LocalHTTPServer?
    private lazy var hub = HubWindowController(
        store: store, permissions: permissions, models: models, notes: noteStore,
        onOpenNote: { [weak self] entry in self?.openNote(entry) })

    private let transcriber = LocalTranscriber()

    /// 录音**开始那一刻**的前台窗口。等转写回来再看前台是谁，就粘到别人窗口里了。
    private var pasteTarget: PasteTarget?

    /// 这一次「按住说话」是不是真的占着录音器。
    ///
    /// ⚠️ 没有这个标记就会丢掉整场长录。⌥Space / ⌥. / ⌥[ 里的那个 ⌥
    /// **就是推杆键本身**：按下它，matcher 立刻发 `.overlayHoldPressed`，
    /// `beginHold()` 已经起录；随后 Space 才到，落笔会话接管同一个录音器；
    /// 最后松开 ⌥ 发 `.overlayHoldReleased` —— 无条件的 `endHold()` 就把
    /// 落笔的录音器停了。面板还显示「录音中」，实际一个采样都没在收，
    /// 停下来永远是 0 段。
    private var holdOwnsRecorder = false
    private var modelDownloading = false

    /// 会话内语言锁定：**两段判出同一种语言才锁**（见 `SessionLanguageLock`）。
    /// Whisper 对短句的自动检测经常判错，一句两个字的中文被当成英文，
    /// 输出就是一串音译垃圾 —— 而第一句恰恰最短最急，最不该由它定生死。
    private var languageLock = SessionLanguageLock()
    private var sessionLanguage: TranscriptionLanguage? { languageLock.locked }
    /// 空闲一段时间就把模型还给系统 —— turbo 常驻 1.5 GB。
    private var unloadTimer: Timer?
    private var modelMenuItem: NSMenuItem?

    /// 落笔的刘海驱动。30 Hz 喂电平，整秒才改文案。
    private var noteNotchTimer: Timer?
    private var lastNoteNotchMessage = ""
    /// 瞬时提示的保护窗：到点之前不覆盖它。
    private var noteNotchHoldUntil: CFAbsoluteTime = 0
    private var noteNotchNeedsRestore = false

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

        // 落笔录音起停 → 刘海。走会话的唯一出口，这样快捷键、面板停止键、
        // 关面板、tick 自愈这四条停止路径都能正确收尾。
        //
        // ⚠️ 必须挂在**所有自测早退分支之前**。挂晚了，任何走
        // `--note-*` 早退的路径都拿不到这个回调，而真实路径上它同样是
        // 排在一长串早退之后才生效 —— 太脆。
        noteSession.onRecordingChanged = { [weak self] recording in
            recording ? self?.startNoteNotch() : self?.finishNoteNotch()
        }

        // 刘海 hover 条上的三个按钮。刘海不认识会话，动作由这里注入。
        notch.hoverActions = .init(
            cut: { [weak self] in self?.cutNow() },
            togglePause: { [weak self] in self?.toggleNotePause() },
            stop: { [weak self] in self?.noteSession.stop() })

        // 贾维斯的接线。它不认识 AppDelegate，会话形状与副作用都由这里注入。
        //
        // ⚠️ 和上面那个回调一样，必须挂在**所有自测早退分支之前** ——
        // 走 `--jarvis-test` 的路径同样要经过这几根线。
        jarvis.noteSessionLive = { [weak self] in self?.noteSession.isLive ?? false }
        jarvis.holdActive = { [weak self] in self?.holdOwnsRecorder ?? false }
        jarvis.abortHold = { [weak self] in self?.abortSpuriousHold() }
        jarvis.onScanningChanged = { [weak self] armed in
            guard let self else { return }
            // A14：armed 时落笔无视「自动断句」开关 —— 段不闭合就永远扫不到命令。
            noteSession.scanArmed = armed
        }
        // A12：**只在**有待执行命令倒计时期间抢占 esc / ↩。遗留 = 用户的
        // Escape 键全系统失效，而屏幕上没有任何解释。
        jarvis.onCountdownChanged = { [weak self] active in
            self?.hotkeys?.jarvisCountdown = active
        }
        jarvis.onHoldNotch = { [weak self] seconds in
            guard let self else { return }
            hideTimer?.invalidate()
            noteNotchHoldUntil = CFAbsoluteTimeGetCurrent() + seconds
            noteNotchNeedsRestore = true
        }
        // 落笔每段转写回来时顺带扫一遍 raw —— 共跑就是这一行。
        noteSession.scanTranscript = { [weak self] transcript in
            self?.jarvis.dispatch(transcript) ?? false
        }

        installStatusItem()

        // 录音自测：录 N 秒，落成 WAV，把提交策略的裁决一并打出来。
        // 麦克风是这一层唯一没法靠单测覆盖的东西 —— 必须真的录一次。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--record-test") {
            let seconds = Double(ProcessInfo.processInfo.arguments[safe: index + 1] ?? "") ?? 3
            runRecordTest(seconds: seconds)
            return
        }

        // 本地转写自测：喂一个 WAV 进去，把模型下载 → 加载 → 转写 → 规则润色
        // 整条走完并打出文字。模型第一次跑要下权重 + CoreML 按芯片编译，会很慢。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--transcribe-test") {
            let path = ProcessInfo.processInfo.arguments[safe: index + 1] ?? ""
            runTranscribeTest(path: path)
            return
        }

        // 全链路自测：右⌥ 按住 → 外放播一段语音让麦克风收 → 松开 → 本地转写
        // → 粘回文本编辑。每一环单独都验过了，这里验它们串起来还成立。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--loop-test") {
            let args = ProcessInfo.processInfo.arguments
            runLoopTest(wav: args[safe: index + 1] ?? "", file: args[safe: index + 2] ?? "")
            return
        }

        // 落笔自测：开一段真实的连续录音，外放喂话，看自动切段、按序落正文、
        // 落盘成一篇笔记这几件事是不是真的发生了。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--note-test") {
            runNoteTest(wav: ProcessInfo.processInfo.arguments[safe: index + 1] ?? "")
            return
        }

        // 模型下载自测：走 ModelCatalog 的完整流程（两个界面共用的状态机）。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--model-download-test") {
            runModelDownloadTest(id: ProcessInfo.processInfo.arguments[safe: index + 1] ?? "")
            return
        }

        // 菜单自测：把托盘菜单（含模型子菜单）的实际结构打出来。
        // 菜单渲染没法截图取证，只能让它自己报自己的结构。
        if ProcessInfo.processInfo.arguments.contains("--menu-dump") {
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
        // 三层插入里哪一层生效、有没有真的落进目标 App，只能这样取证。
        if ProcessInfo.processInfo.arguments.contains("--paste-test") {
            runPasteTest()
            return
        }

        // 热键自测：合成一次真实的右 ⌥ 按住并松开，走完整条
        // CGEventPost → HID tap → 匹配器 → 录音 的链路。
        // 单测覆盖不到 tap 本身，而真机按键又没法在这里取证 —— 只能自己发事件。
        if ProcessInfo.processInfo.arguments.contains("--hotkey-selftest") {
            runHotkeySelfTest()
            return
        }

        // ⌥Space 起长录的回归自测：右⌥ 的按下会先起一次「按住说话」，
        // 松开时不能把落笔的录音器一并停掉。
        if ProcessInfo.processInfo.arguments.contains("--note-hotkey-test") {
            runNoteHotkeyTest()
            return
        }

        // 编辑模式自测：防抖落盘、撤销/重做、字数、截图插入、删除。
        if ProcessInfo.processInfo.arguments.contains("--note-edit-test") {
            runNoteEditTest()
            return
        }

        // 手动断句自测：右⌥ **单击**要能切段，且不能和「按住说话」打架。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--note-cut-test") {
            runNoteCutTest(wav: ProcessInfo.processInfo.arguments[safe: index + 1] ?? "")
            return
        }

        // 截图接线自测：功能开关、热键绑定、端到端插图。
        if ProcessInfo.processInfo.arguments.contains("--screenshot-test") {
            runScreenshotTest()
            return
        }

        // 刘海 hover 条自测：悬停展开、按钮点得动、暂停/继续、click-through 还原。
        if ProcessInfo.processInfo.arguments.contains("--note-hover-test") {
            runNoteHoverTest()
            return
        }

        // 编辑器按键自测：⌘B / Tab / 回车 / ⌘Z 走真实 CGEvent。
        if ProcessInfo.processInfo.arguments.contains("--note-key-test") {
            runNoteKeyTest()
            return
        }

        // 贾维斯自测：待命 → 扫描 → 命中 → 倒计时 → 撤销 / 真的执行。
        if ProcessInfo.processInfo.arguments.contains("--jarvis-test") {
            runJarvisTest()
            return
        }

        // ask 手势自测：双击右⌥ 并按住 → 提问态；关掉开关则退化成普通听写。
        if ProcessInfo.processInfo.arguments.contains("--ask-test") {
            runAskTest()
            return
        }

        // Claude Code 助手自测：真的问两句，验第二句接得住第一句的上下文。
        if ProcessInfo.processInfo.arguments.contains("--claude-test") {
            runClaudeTest()
            return
        }

        // 集成自测：两道门禁 + /api/notes 的五条路由 + MCP 桥落盘。
        if ProcessInfo.processInfo.arguments.contains("--integration-test") {
            startIntegrationServer()
            runIntegrationTest()
            return
        }

        // 验证入口：屏幕捕获受 TCC 限制、刘海又是 click-through 的，
        // 所以「它到底渲染成什么样」只能靠这条通道取证。
        // 这是 spec/04 §3.2 那套 /debug 路由在原生版的最小对应物。
        // 合并窗某一页的取证：把这一页真正画出来的文字读回来。
        // 「构建通过」和「这一页画出来了」是两件事 —— 设置页尤其容易只剩空壳。
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--verify-page") {
            let name = ProcessInfo.processInfo.arguments[safe: index + 1] ?? "integration"
            runVerifyPage(name: name)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--verify-windows") {
            hub.show(page: .operators)
            notePanel.show()
            notch.show(state: .recording, message: "停顿自动切段 · ⌥. 手动切")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                selfTest = true
                // AX 读自己的窗口树要求 App 处在激活态，否则 kAXWindows 返回空数组。
                NSApp.activate(ignoringOtherApps: true)
                Thread.sleep(forTimeInterval: 0.6)
                emit(self.debugGeometry())
                // 窗口截图受 TCC 限制，但本进程有辅助功能授权 —— 可以走 AX
                // 把自己渲染出来的文字读回来，这是唯一能证明「页面真的画出来了」
                // 而不只是「构建通过」的通道。
                // AX 自读窗口树在本机时灵时不灵（返回空数组），截图又被 TCC 挡着。
                // NSView 树是第三条路：SwiftUI 真的画出东西了，这里就有对应的
                // 宿主视图与文本视图；画不出来就是一层空壳。
                emit("落笔面板视图树：")
                for line in Self.viewTree(notePanel.debugContentView) { emit("  \(line)") }
                emit("合并窗文字：")
                for line in Self.axTexts(pid: getpid()) { emit("  \(line)") }
                Log.flush()
                exit(0)
            }
            return
        }

        // 首启，**或者**老用户的辅助功能授权被撤销了 —— 两种情况都弹引导。
        // 辅助功能授权因为 CDHash 变动而失效是常事，只打开设置窗不足以让用户
        // 知道该做什么，完整的引导会一步步带他重新授权。
        if !store.settings.hasCompletedOnboarding || !permissions.isGranted(.accessibility) {
            showOnboarding()
        }

        startHotkeys()
        startIntegrationServer()

        // 预热本地模型：第一次按住说话不该等几秒的 CoreML 编译。
        // 权重没下过就跳过 —— 静默拉 1.5 GB 是不能接受的。
        let modelID = store.settings.selectedLocalModelId
        if let model = LocalModels.definition(id: modelID),
           LocalTranscriber.isDownloaded(model) {
            Task { [transcriber] in await transcriber.prewarm(modelID: modelID) }
        }
        if store.settings.noteWantsSpeakerLabels {
            Task { [transcriber] in await transcriber.prewarmDiarization() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        httpServer?.stop()
    }

    // MARK: - 本地集成服务

    /// 起 127.0.0.1:48765。
    ///
    /// **总是**起 —— `/health` 与 `/debug/*` 是这套 UI 唯一的取证通道
    /// （截图受 TCC 限制、刘海是 click-through 的）。真正碰用户数据的
    /// `/api/*` 另有两道门：设置开关 + bearer token。
    private func startIntegrationServer() {
        let server = LocalHTTPServer(port: IntegrationStore.port) { [weak self] request in
            guard let self else { return (503, "{\"ok\":false,\"message\":\"shutting down\"}") }
            return integration.handle(request)
        }
        guard server.start() else { return }
        httpServer = server
        // 每次启动都把内嵌的 MCP 桥重写一遍：App 升级后磁盘上那份自动最新，
        // 而用户注册进编码助手的那条路径保持不变。
        IntegrationStore.exportMCPScript()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }


    // MARK: - 菜单栏

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 品牌字形（水滴 + 两道涟漪）在资源接上之前，先用系统符号占位。
            // 必须是 template 才能跟随菜单栏色并自动适配明暗。
            let image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Inkfall")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        // 托盘的「笔记」落在主页，「设置」落在设置子页 —— 主页工具栏没有设置
        // 按钮以外的入口，所以这两项是可发现的那两条路。
        menu.addItem(withTitle: "笔记", action: #selector(showNotes), keyEquivalent: "h")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "落笔面板", action: #selector(toggleNotePanel), keyEquivalent: "")
        menu.addItem(.separator())
        let models = NSMenuItem(title: "本地模型", action: nil, keyEquivalent: "")
        models.submenu = buildModelMenu()
        menu.addItem(models)
        modelMenuItem = models
        menu.addItem(withTitle: "刘海自测", action: #selector(testOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "重新打开引导", action: #selector(reopenOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出落音", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quit)
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    /// 模型子菜单：勾选当前在用的，标出已下载/未下载，并给出下载与删除。
    ///
    /// 每次打开都重建 —— 下载状态是磁盘上的事实，缓存了就会骗人。
    private func buildModelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // ⚠️ 必须关掉自动启用：开着时 AppKit 只按「target 响应得了 action 吗」
        // 决定可用性，我们手动设的 isEnabled 会被忽略。
        menu.autoenablesItems = false
        models.refresh()
        for entry in models.entries {
            let suffix = entry.downloaded ? "已下载 \(entry.sizeText)"
                                          : "未下载 \(entry.sizeText)"
            let item = NSMenuItem(title: "\(entry.model.name) · \(suffix)",
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.representedObject = entry.id
            item.state = entry.id == models.selectedID ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let downloaded = models.selected?.downloaded ?? false
        let download = NSMenuItem(
            title: downloaded ? "重新下载当前模型" : "下载当前模型",
            action: #selector(downloadLocalModel), keyEquivalent: "")
        download.target = self
        menu.addItem(download)

        let delete = NSMenuItem(title: "删除当前模型的权重",
                                action: #selector(deleteLocalModel), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = downloaded
        menu.addItem(delete)

        let reveal = NSMenuItem(title: "在访达中显示权重目录",
                                action: #selector(revealModelFolder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != models.selectedID,
              let model = LocalModels.definition(id: id) else { return }
        models.select(id)
        flash(models.selected?.downloaded == true ? .success : .cancelled,
              models.selected?.downloaded == true
                  ? "已切到 \(model.name)" : "\(model.name)：还没下载",
              seconds: 1.6)
    }

    @objc private func deleteLocalModel() {
        guard let entry = models.selected else { return }
        models.delete(entry.id)
        flash(.success, "已删除 \(entry.model.name) 的权重", seconds: 1.6)
    }

    @objc private func revealModelFolder() {
        try? FileManager.default.createDirectory(
            at: LocalTranscriber.modelRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([LocalTranscriber.modelRoot])
    }

    @objc private func reopenOnboarding() { showOnboarding() }

    @objc private func showNotes() { hub.show(page: .home) }
    @objc private func showSettings() { hub.show(page: .operators) }
    @objc private func toggleNotePanel() { notePanel.toggle() }

    /// 刘海自测：把几个状态依次画一遍。录音管线接上之前，
    /// 这是唯一能看到墨锭真实渲染的方式（截图受 TCC 限制）。
    @objc private func testOverlay() {
        let beats: [(OverlayState, String, Double)] = [
            (.recording, "停顿自动切段 · ⌥. 手动切", 0),
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
            emit(String(format: "中途 level=%.4f 有效语音=%.0fms 已录=%.2fs",
                        recorder.level, recorder.activeAudioMs, recorder.takeDurationSeconds))
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
            emit("① 目标在前台：route=\(routeA.rawValue)")

            // 切走再插一次，走跨 App 的 B1/B2。
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
            Thread.sleep(forTimeInterval: 0.8)
            let markerB = "落音乙\(Int.random(in: 1000...9999))"
            let routeB = MacAutomation.insert(markerB, into: target)
            emit("② 跨 App：route=\(routeB.rawValue)")

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
                        ? [:] : store.settings.transcriptionReplacements,
                    diarize: ProcessInfo.processInfo.arguments.contains("--diarize"))
                // 连跑三遍：第一遍含模型加载，后两遍才是常驻时的真实延迟。
                // 同时也是回归 —— 同一个实例上重复转写必须每次都出同样的文字。
                var texts: [String] = []
                for round in 1...3 {
                    let r = try await transcriber.transcribe(request)
                    texts.append(r.text)
                    emit(String(format: "第 %d 遍 %.2fs lang=%@ 说话人=%@ → 「%@」",
                                round, round == 1 ? Date().timeIntervalSince(started) : r.elapsed,
                                r.language ?? "?", r.speakerCount.map(String.init) ?? "-", r.text))
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
                && selfTestEvents.contains(.longRecordingFlushTap)
            emit(ok ? "✅ 热键链路通" : "❌ 事件不完整")
            Log.flush()
            exit(ok ? 0 : 1)
        }
    }

    /// ⌥Space 起长录的回归自测。
    ///
    /// 盯的是这个：右⌥ 按下时 matcher 必然先发一次 `.overlayHoldPressed`，
    /// `beginHold()` 已经起录；Space 随后才到。松开右⌥ 的
    /// `.overlayHoldReleased` 曾经无条件 `endHold()`，把落笔会话的录音器
    /// 停掉 —— 面板显示「录音中」，实际一个采样都没收，停下来永远 0 段。
    /// 所以断言的是**松开右⌥ 若干秒之后录音器还活着、计时还在走**。
    private func runNoteHotkeyTest() {
        selfTest = true
        guard AXIsProcessTrusted() else {
            emit("未授权辅助功能")
            Log.flush()
            exit(1)
        }
        startHotkeys()
        emit("tap 已启用 —— 合成 ⌥Space")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            emit("→ 右⌥ 按下")
            Self.postRightOption(down: true)
        }
        // 人手按 ⌥Space，⌥ 与 Space 之间必然隔着几十到几百毫秒。
        // 这段迟滞正是 bug 的窗口，不能压缩掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            emit("按住 ⌥ 中：推杆录音=\(recorder.isRecording)")
            emit("→ Space 敲一下")
            Self.postSpace(down: true)
            Self.postSpace(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [self] in
            emit("会话已开：落笔录音=\(noteSession.isRecording) 录音器=\(recorder.isRecording)")
            emit("→ 右⌥ 松开")
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [self] in
            let held = noteSession.isRecording && recorder.isRecording
            emit("松开 4 秒后：落笔录音=\(noteSession.isRecording) "
                 + "录音器=\(recorder.isRecording) 计时=\(noteSession.elapsedSeconds)s "
                 + String(format: "本段已录=%.2fs", recorder.takeDurationSeconds))
            emit("收到事件：\(selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            // 计时器还在走 = tick 没被 recorder 掉线卡住。
            let ticking = noteSession.elapsedSeconds >= 3
            // 刘海：长录期间必须亮着，而且是落笔胶囊（几何要给 hover 条留高度）。
            let notchOK = notch.isVisible && notch.debugIsCompact
            emit("刘海：可见=\(notch.isVisible) 紧凑胶囊=\(notch.debugIsCompact) "
                 + "文案=「\(notch.debugMessage)」\(notch.debugCapsule)")
            let ok = held && ticking && notchOK
            emit(ok ? "✅ 长录锁得住 + 刘海在" : "❌ "
                 + (notchOK ? "录音状态没锁住" : "刘海没显示"))
            noteSession.cancel()
            // 停下来之后刘海要收尾（有段就转写中，没段就直接收）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                emit("停止后：刘海可见=\(notch.isVisible)")
                Log.flush()
                exit(ok ? 0 : 1)
            }
        }
    }

    private static func postSpace(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: 49, keyDown: down) else { return }
        // 右⌥ 还按着，所以 alternate 位（共享位 + 设备位）必须带上，
        // 否则 matcher 眼里这就是一个裸 Space。
        event.flags = CGEventFlags(rawValue: 0x80000 | 0x40)
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

    private func runNoteTest(wav: String) {
        selfTest = true
        guard recorder.microphoneAuthorized else {
            emit("麦克风未授权")
            Log.flush()
            exit(1)
        }
        notePanel.show()
        noteSession.debugSegmentTrace = true
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--dump-levels") {
            noteSession.debugLevelDumpPath = ProcessInfo.processInfo.arguments[safe: index + 1]
        }
        guard noteSession.start() else {
            emit("起录失败")
            Log.flush()
            exit(1)
        }
        emit("会话开始 noteID=\(noteSession.noteID ?? "?") 模式=\(noteSession.mode)")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [wav]
            try? player.run()
            player.waitUntilExit()
            Thread.sleep(forTimeInterval: 2.0)   // 让尾段的停顿把最后一刀切出来

            DispatchQueue.main.async { [self] in
                emit("停止前：段数=\(noteSession.segments.count) 在飞=\(noteSession.inFlight)")
                noteSession.debugFlushLevelDump()
                // 录音中的面板走 markdown 预览 —— 这是唯一能看到它真的画出来了
                // 的时机（截图被 TCC 挡着，AX 自读窗口树在本机不可靠）。
                emit("录音中的面板视图树：")
                for line in Self.viewTree(notePanel.debugContentView) { emit("  \(line)") }
                noteSession.stop()
                waitForNote(ticks: 0)
            }
        }
    }

    private func waitForNote(ticks: Int) {
        // 在飞的段停下来之后还要转完 —— 这正是「绝不丢数据」那条要验的。
        if noteSession.inFlight > 0, ticks < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                waitForNote(ticks: ticks + 1)
            }
            return
        }
        emit("停止后：模式=\(noteSession.mode) 段数=\(noteSession.segments.count)")
        for segment in noteSession.segments {
            emit("  段 \(segment.id) [\(segment.status.rawValue)] \(segment.displayText)")
        }
        emit("草稿正文：\(noteSession.draft)")
        let saved = noteStore.notes.first
        emit("落盘笔记：id=\(saved?.id ?? "无") 标题=\(saved?.title ?? "-")")
        emit("落盘正文：\(saved?.finalText ?? "")")
        let ok = noteSession.segments.count >= 1
            && !(saved?.finalText.isEmpty ?? true)
            && saved?.id == noteSession.noteID
        emit(ok ? "✅ 落笔：连续录音 → 自动切段 → 按序落正文 → 落盘 通"
                : "❌ 落笔链路不完整")
        Log.flush()
        exit(ok ? 0 : 1)
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

    /// 打印 NSView 树。只保留有实际尺寸的节点，并把 NSTextView 的内容摘出来 ——
    /// 那是「编辑器真的活着」最直接的证据。
    private static func viewTree(_ root: NSView?, depth: Int = 0) -> [String] {
        guard let root, depth < 12 else { return [] }
        var out: [String] = []
        let size = root.frame.size
        var line = String(repeating: "  ", count: depth)
            + "\(type(of: root)) \(Int(size.width))×\(Int(size.height))"
        // 背景取证。白屏这类问题看视图树的形状永远看不出来 —— 形状是对的，
        // 是某一层在画浅色。所以把 drawsBackground / backgroundColor 打出来。
        func describe(_ color: NSColor?) -> String {
            guard let rgb = color?.usingColorSpace(.deviceRGB) else { return "?" }
            if rgb.alphaComponent < 0.01 { return "clear" }
            return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)",
                          rgb.redComponent, rgb.greenComponent,
                          rgb.blueComponent, rgb.alphaComponent)
        }
        if let text = root as? NSTextView {
            line += " ← 文本 \(text.string.count) 字"
                + " draws=\(text.drawsBackground) bg=\(describe(text.backgroundColor))"
        }
        if let scroll = root as? NSScrollView {
            line += " ← draws=\(scroll.drawsBackground) bg=\(describe(scroll.backgroundColor))"
        }
        if let clip = root as? NSClipView {
            line += " ← draws=\(clip.drawsBackground) bg=\(describe(clip.backgroundColor))"
        }
        out.append(line)
        for child in root.subviews where child.frame.width > 1 && child.frame.height > 1 {
            out += viewTree(child, depth: depth + 1)
        }
        return out
    }

    /// 走 AX 把本进程窗口里的可见文字全读出来。
    private static func axTexts(pid: pid_t) -> [String] {
        var out: [String] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 24 else { return }
            func string(_ attribute: String) -> String? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element, attribute as CFString, &value) == .success,
                    let text = value as? String,
                    !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return text
            }
            let role = string(kAXRoleAttribute) ?? "?"
            let labels = [string(kAXValueAttribute), string(kAXTitleAttribute),
                          string(kAXDescriptionAttribute)].compactMap { $0 }
            if !labels.isEmpty {
                // 按钮之类的交互元件单独标出来 —— 只看文本读不出「能不能点」。
                let prefix = role == "AXButton" ? "[按钮] " : ""
                out.append(prefix + labels.joined(separator: " | "))
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement] else { return ["（读不到窗口）"] }
        for window in list { walk(window, depth: 0) }
        return out
    }

    /// 供外部验证脚本读取的窗口几何（截图被 TCC 挡住，只能这样取证）。
    func debugGeometry() -> String {
        var lines: [String] = []
        if let f = notch.debugFrame { lines.append("notch \(f)  \(notch.debugCapsule)") }
        if let f = notePanel.debugFrame { lines.append("note \(f)") }
        if let f = hub.debugFrame { lines.append("hub \(f)") }
        return lines.joined(separator: "\n")
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

        // 双击右⌥ 并按住 = 向助手提问（spec/01 §2.2）。转写出来的问题连同
        // 当前选区一起交给 Claude Code，答案显示出来而**不粘贴**。
        // 关掉 ask 模式、或本机没有 claude 时退化成普通按住说话 ——
        // 手势坏掉比手势没有更糟。
        case .askHoldPressed:
            holdIsAsk = jarvis.askAvailable
            beginHold()

        case .overlayHoldReleased, .askHoldReleased:
            endHold()

        case .cancelRecordingPressed:
            abortSpuriousHold()
            if noteSession.isLive {
                // 落笔用**优雅停止**：在飞的段照常转写保存，绝不丢数据。
                noteSession.stop()
            } else if recorder.isRecording {
                recorder.cancel()
                stopLevelTicker()
                flash(.cancelled, "已取消", seconds: 1.2)
            } else if notePanel.isVisible {
                notePanel.hide()
            }

        case .flushSegmentPressed:
            abortSpuriousHold()
            if noteSession.isPaused {
                noteFlash(.cancelled, "已暂停，先继续", seconds: 1.2)
            } else if noteSession.isRecording {
                reportCut(noteSession.flushNow())
            } else if !recorder.isRecording {
                // Fn 推杆用户的常见情形：松开 Fn 去按组合键时录音其实已经停了。
                flash(.cancelled, "未在录音", seconds: 1.2)
            }

        // 右⌥ **单击**（按下再松开，中间没碰过任何别的键）：**一键两用**。
        //
        // - 有没粘出去的段 → 把它们合成一次插进目标窗口（对齐 Tauri 的
        //   `note_paste_all`：按段序、单换行连接、一次插入）
        // - 没有待粘内容 → 当作手动切段
        //
        // Tauri 版是靠「贾维斯扫描是否 armed」来分这两个含义的；原生版还没有
        // 贾维斯，所以改用「有没有待粘内容」来分 —— 这也正是用户按它时
        // 心里想的那件事。想要无条件切段永远有 ⌥.。
        //
        // 与「按住说话」不冲突：长录期间 `beginHold()` 有
        // `guard !noteSession.isRecording`，所以这一次按下根本没起录。
        // 组合键（⌥Space / ⌥. / ⌥[）结束时的松开不会走到这里 ——
        // matcher 的污染检测会把它们排除掉（三条单测钉着）。
        case .longRecordingFlushTap:
            guard noteSession.isLive else { break }
            if noteSession.hasUnpasted {
                let count = noteSession.pasteAllUnpasted()
                noteFlash(.success, "已插入 \(count) 段", seconds: 1.4)
            } else if noteSession.isRecording {
                reportCut(noteSession.flushNow())
            } else {
                noteFlash(.cancelled, "已暂停，没有待粘内容", seconds: 1.2)
            }

        case .noteModePressed:
            // ⌥ 按下的那一刻已经起了一截「按住说话」，那是组合键的副产物
            // 而不是说话内容。先把它丢掉，再接管录音器。
            abortSpuriousHold()
            // ⌥Space 是「开始/停止落笔录音」，不是「显示/隐藏面板」——
            // 面板只是这件事的可视化。
            if noteSession.isLive {
                noteSession.stop()
            } else {
                notePanel.show()
                guard noteSession.start() else {
                    flash(.error, "麦克风未授权", seconds: 2.0)
                    return
                }
            }
            hotkeys?.noteTogglesActive = notePanel.isVisible

        // ⌥, 关键词待命。**扫描是 filter**：落笔开着时它叠加上去，
        // 两者共跑（每段既留下又扫描），而不是二选一。
        case .jarvisTogglePressed:
            // ⚠️ 不在这里 abortSpuriousHold()：动作表里「把刚起头的 hold 转成
            // 待命会话」是一条**正当分支**，得由 `toggle()` 自己决定丢不丢。
            let refused = !jarvis.featureEnabled
            Log.write("hotkey: ⌥, 贾维斯开关（功能已开=\(!refused)）")
            if let message = jarvis.toggle() {
                // ⚠️ 一律走 noteFlash。`flash` 不设保护窗，长录期间计时每跳一秒
                // 就把它盖掉 —— 用户按了 ⌥, 只看到刘海闪一下又变回计时，
                // 读成「快捷键失效」。noteFlash 在没有会话时会自己回落到 flash。
                noteFlash(refused ? .error : (jarvis.scanning ? .success : .cancelled),
                          message, seconds: refused ? 2.4 : 1.6)
            }
            // 功能没开时**把设置页打开到那一栏**。⌥, 是这个功能唯一的入口，
            // 而一句「去设置里开」对一个已经按了快捷键的人来说太远了。
            if refused { hub.show(page: .voiceCommands) }

        // 这两个键**只在倒计时期间**能走到这里（matcher 的 jarvisCountdown 门）。
        case .jarvisUndoPressed:
            _ = jarvis.undo()

        case .jarvisRunNowPressed:
            _ = jarvis.runNow()

        case .historyPickerPressed:
            abortSpuriousHold()
            hub.show(page: .home)

        // 截图：⌥; 框选、⌥' 整屏。都直接插进当前笔记的正文。
        case .selectScreenshotRegionPressed:
            abortSpuriousHold()
            captureIntoNote(.region)

        case .captureScreenshotPressed:
            abortSpuriousHold()
            captureIntoNote(.fullScreen)

        // 落笔的三个开关：右⌥ + S / P / V。面板开着的时候才生效
        // （`noteTogglesActive` 已经在 noteModePressed 里跟着面板走）。
        case .noteAutoSegToggle:
            abortSpuriousHold()
            noteSession.autoSegment.toggle()
            flash(.success, noteSession.autoSegment ? "自动分段 开" : "自动分段 关", seconds: 1.2)

        case .noteAutoPasteToggle:
            abortSpuriousHold()
            noteSession.autoPaste.toggle()
            flash(.success, noteSession.autoPaste ? "自动粘贴 开" : "自动粘贴 关", seconds: 1.2)

        case .noteDiarizeToggle:
            abortSpuriousHold()
            guard noteSession.diarizationReady else {
                flash(.error, "分离模型未下载", seconds: 2.0)
                return
            }
            noteSession.diarize.toggle()
            flash(.success, noteSession.diarize ? "区分人物 开" : "区分人物 关", seconds: 1.2)

        default:
            // 其余事件的消费端（转写、加工、粘贴、贾维斯）尚未接入。
            Log.write("hotkey: \(event) —— 消费端未接入")
        }
    }

    /// 手动断句的自测。
    ///
    /// 把**自动断句关掉**，这样唯一能产生中间那一刀的就只有右⌥ 单击 ——
    /// 否则数出来的段数分不清是谁切的。
    /// 刘海 hover 条自测。
    ///
    /// 这条链上没有一环是单测能覆盖的：命中靠轮询全局鼠标，展开靠临时关掉
    /// click-through，按钮能不能收到点击又取决于 `acceptsFirstMouse`
    /// （overlay 永远不是键窗口）。所以只能合成真实鼠标事件走一遍。
    private func runNoteHoverTest() {
        selfTest = true
        startHotkeys()
        guard noteSession.start() else {
            emit("起录失败 —— 麦克风没授权？")
            Log.flush()
            exit(1)
        }
        var failures = 0

        func check(_ label: String, _ ok: Bool) {
            emit("\(ok ? "  ✓" : "  ✗") \(label)")
            if !ok { failures += 1 }
        }

        // ⚠️ 必须用 asyncAfter 链，不能用 RunLoop.run(until:) —— 后者不泵
        // AppKit 的事件队列，合成出去的 CGEvent 永远送不回本 App。
        var steps: [(Double, () -> Void)] = []

        steps.append((0.4, {
            emit("落笔已开：刘海可见=\(self.notch.isVisible) 文案=「\(self.notch.debugMessage)」")
            check("默认 click-through", !self.notch.debugAcceptsClicks)
            guard let rect = self.notch.debugCapsuleRect else {
                emit("  ✗ 拿不到胶囊矩形"); failures += 1; return
            }
            emit("  胶囊 \(Int(rect.width))x\(Int(rect.height)) @(\(Int(rect.minX)),\(Int(rect.minY)))")
            Self.moveMouse(to: CGPoint(x: rect.midX, y: rect.midY))
        }))

        // 轮询周期 120ms，留够两拍。
        steps.append((0.4, {
            check("悬停展开了条（hover=\(self.notch.debugHover)）", self.notch.debugHover == "strip")
            check("临时收下了鼠标事件", self.notch.debugAcceptsClicks)
            let height = self.notch.debugCapsuleRect?.height ?? 0
            check("胶囊为条撑高了（\(Int(height))）",
                  height >= OverlayGeometry.noteHoverStripSpan)
            // 先点第一个（切段）。此刻一个字都没录，所以它应当报「没有声音」——
            // 那句反馈本身就是「按钮真的接到了会话」的证据。
            if let point = self.stripButtonCenter(index: 0) {
                emit("  点「切段」@(\(Int(point.x)),\(Int(point.y)))")
                Self.clickMouse(at: point)
            } else { emit("  ✗ 算不出按钮位置"); failures += 1 }
        }))

        steps.append((0.5, {
            check("切段按钮接到了会话（\(self.notch.debugMessage)）",
                  self.notch.debugMessage.contains("没有声音"))
            if let point = self.stripButtonCenter(index: 1) {
                emit("  点「暂停」@(\(Int(point.x)),\(Int(point.y)))")
                Self.clickMouse(at: point)
            }
        }))

        steps.append((0.6, {
            check("暂停生效了", self.noteSession.isPaused)
            check("录音器真的停了", !self.recorder.isRecording)
            check("刘海换成暂停态（\(self.notch.debugMessage)）",
                  self.notch.debugMessage.contains("已暂停"))
            self.hoverTestFrozenSeconds = self.noteSession.elapsedSeconds
            emit("  冻结于 \(self.hoverTestFrozenSeconds)s，接下来停 4 秒")
        }))

        // 在暂停里待够久，让「冻没冻住」这件事真的可观测 ——
        // 停半秒就断言「没多算」是测不出东西的。
        steps.append((4.0, {
            let now = self.noteSession.elapsedSeconds
            check("停了 4 秒计时纹丝不动（\(self.hoverTestFrozenSeconds)s → \(now)s）",
                  now == self.hoverTestFrozenSeconds)
            check("刘海文案也冻着（\(self.notch.debugMessage)）",
                  self.notch.debugMessage.contains("已暂停"))
            // 条还在（鼠标没动），再点一次同一个位置 = 继续。
            if let point = self.stripButtonCenter(index: 1) { Self.clickMouse(at: point) }
        }))

        steps.append((0.8, {
            check("继续生效了", self.noteSession.isRecording)
            check("录音器又起来了", self.recorder.isRecording)
        }))

        // 继续之后要接着往上走，而不是从头数，也不是把那 4 秒补回来。
        steps.append((2.2, {
            let now = self.noteSession.elapsedSeconds
            check("继续后接着走（\(self.hoverTestFrozenSeconds)s → \(now)s）",
                  now > self.hoverTestFrozenSeconds)
            check("那 4 秒没有被补回来", now < self.hoverTestFrozenSeconds + 4)
            // ⚠️ 不能「移回测试开始时的位置」—— 鼠标本来就可能停在刘海上，
            // 那样一移回去还在条里，「移开」这一支根本没被测到（实测踩过）。
            // 挑一个确定在胶囊之外的点：胶囊所在屏的正中。
            guard let rect = self.notch.debugCapsuleRect else { return }
            let away = CGPoint(x: rect.midX, y: rect.minY - 300)
            emit("  移到 (\(Int(away.x)),\(Int(away.y)))，胶囊下沿 \(Int(rect.minY))")
            Self.moveMouse(to: away)
        }))

        steps.append((0.5, {
            emit("  鼠标现在 \(NSEvent.mouseLocation)")
            check("移开就收条", self.notch.debugHover == "none")
            check("click-through 已还回去", !self.notch.debugAcceptsClicks)
            // 移回来，验第三个按钮。
            if let rect = self.notch.debugCapsuleRect {
                Self.moveMouse(to: CGPoint(x: rect.midX, y: rect.midY))
            }
        }))

        steps.append((0.4, {
            check("移回来又展开", self.notch.debugHover == "strip")
            if let point = self.stripButtonCenter(index: 2) {
                emit("  点「停止」@(\(Int(point.x)),\(Int(point.y)))")
                Self.clickMouse(at: point)
            }
        }))

        steps.append((0.6, {
            check("停止按钮收了会话", !self.noteSession.isLive)
            check("停会话后 click-through 仍然是还回去的", !self.notch.debugAcceptsClicks)
            emit(failures == 0 ? "✅ hover 条通" : "❌ \(failures) 项不过")
            Log.flush()
            exit(failures == 0 ? 0 : 1)
        }))

        var delay: Double = 0
        for (gap, step) in steps {
            delay += gap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }

    private var hoverTestFrozenSeconds = 0

    /// hover 条上第 `index` 个按钮的中心（屏幕坐标，Cocoa 左下原点）。
    ///
    /// 条的排版：左右各 10 内边距、三个等宽按钮、间距 6、高 24、底部留 6。
    private func stripButtonCenter(index: Int) -> CGPoint? {
        guard let rect = notch.debugCapsuleRect else { return nil }
        let inset: Double = 10, gap: Double = 6, count: Double = 3
        let width = (rect.width - inset * 2 - gap * (count - 1)) / count
        let x = rect.minX + inset + (width + gap) * Double(index) + width / 2
        return CGPoint(x: x, y: rect.minY + 6 + 12)
    }

    /// CGEvent 的原点在主屏左上角，NSScreen 在左下角 —— Y 要翻。
    private static func flipped(_ point: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    private static func moveMouse(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: flipped(point), mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func clickMouse(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let target = flipped(point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// 打开合并窗的某一页，把它真的渲染出来的文字读回来。
    private func runVerifyPage(name: String) {
        selfTest = true
        guard let page = HubModel.Page(rawValue: name) else {
            emit("未知页 \(name)，可选：" + HubModel.Page.allCases.map(\.rawValue)
                .joined(separator: " / "))
            Log.flush()
            exit(1)
        }
        store.readOnly = true          // 渲染设置页时 SwiftUI 会写绑定 —— 别落盘
        hub.show(page: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            NSApp.activate(ignoringOtherApps: true)
            // AX 读自己的窗口树要求 App 处在激活态，否则 kAXWindows 返回空数组。
            Thread.sleep(forTimeInterval: 0.6)
            emit("「\(page.title)」页的文字：")
            // 两条路一起走：SwiftUI 的 `Text` 落到 AppKit 上不是 NSTextField
            // 而是私有绘制层，只有 AX 树看得见它；而输入框与开关反过来 ——
            // NSView 树里才有。少任何一条都会把「画出来了」看成「空壳」。
            var texts = Self.axTexts(pid: getpid())
            Self.collectText(hub.debugContentView, into: &texts)
            for line in texts { emit("  \(line)") }
            emit("共 \(texts.count) 段文字")
            // 一页真的画出来了，至少会有页标题和若干行说明；空壳只会剩个框。
            let ok = texts.count >= 6
            emit(ok ? "✅ 这一页画出来了" : "❌ 这一页是空壳")
            Log.flush()
            exit(ok ? 0 : 1)
        }
    }

    /// 从 NSView 树里把 SwiftUI 渲染出来的文字捞出来。
    ///
    /// SwiftUI 的 `Text` 落到 AppKit 上不是 NSTextField，而是私有的绘制层，
    /// 所以要走它的 accessibility 值 —— 那是唯一稳定暴露文字的口子。
    private static func collectText(_ view: NSView?, into out: inout [String]) {
        guard let view else { return }
        for candidate in [view.accessibilityValue(), view.accessibilityLabel()] {
            guard let text = candidate as? String ?? candidate.map({ "\($0)" }),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text != "0" else { continue }
            out.append(String(text.prefix(90)))
            break
        }
        for child in view.subviews { collectText(child, into: &out) }
    }

    // MARK: - 贾维斯自测

    /// 贾维斯的端到端自测。
    ///
    /// 盯的是这几件**单测覆盖不到**的事：待命真的占住了麦克风、扫描 armed 会
    /// 把刘海撑宽、命中之后 esc/↩ 的抢占开了又关得干净（A12）、以及命令**真的
    /// 在终端里跑起来了**。最后一条只能靠让命令写一个文件再读回来取证。
    ///
    /// 用的是一条无害的 `echo > /tmp/...`，并且 `keepFocus`（`open -g`）——
    /// 自测不该把终端窗口怼到用户脸上。
    private func runJarvisTest() {
        selfTest = true
        startHotkeys()

        store.readOnly = true          // 自测绝不能把用户的配置改了
        let stamp = "\(Int(Date().timeIntervalSince1970))"
        let marker = "落音贾维斯\(Int.random(in: 1000...9999))"
        let outputPath = "/tmp/inkfall-jarvis-test-\(stamp).txt"
        // ⚠️ 只改内存里的设置，**不 save()** —— 自测不能把用户的配置改了。
        //
        // 两个总开关**先关着**：第一段用例复现的正是用户报的那个症状
        // （默认就是关的，所以「按了没反应」是绝大多数人遇到的第一件事）。
        // 后面的用例会在自己那一步把它们打开。
        store.settings.jarvisModeEnabled = false
        store.settings.voiceCommandsEnabled = false
        store.settings.voiceCommands = [
            VoiceCommand(keyword: "测试助手",
                         commandTemplate: "echo \"{text}\" > \(outputPath)",
                         terminal: .terminal, enabled: true,
                         keywordPosition: .anywhere, keepFocus: true)
        ]

        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            emit("\(ok ? "  ✓" : "  ✗") \(label)")
            if !ok { failures += 1 }
        }

        var steps: [(Double, () -> Void)] = []

        // ——— 症状复现：功能关着 + 长录中按 ⌥,。
        //
        // 拒绝那句话以前走的是 `flash`，它不设保护窗；而落笔的刘海是 30 Hz 在
        // 重画的，计时每跳一秒就把它盖掉 —— 用户只看到刘海闪一下又变回计时，
        // 读成「快捷键失效」。所以这里要断言它**过一秒还在**。
        steps.append((0.3, {
            emit("——— 功能关着时 ———")
            check("落笔起来了（模拟常时录音）", self.noteSession.start())
            emit("→ 合成 ⌥,（此时两个开关都是关的）")
            Self.postRightOption(down: true)
        }))
        steps.append((0.4, { Self.postKeyWithRightOption(43) }))
        steps.append((0.4, { Self.postRightOption(down: false) }))
        steps.append((0.5, {
            emit("  刘海：「\(self.notch.debugMessage)」")
            check("说了句人话（不是默默无视）",
                  self.notch.debugMessage.contains("贾维斯没开"))
            check("没有真的 arm 起来", !self.jarvis.scanning)
        }))
        steps.append((1.4, {
            // 关键的一条：一秒之后计时已经跳过至少一次，那句话必须还在。
            emit("  1.9 秒后刘海：「\(self.notch.debugMessage)」")
            check("提示没有被落笔的计时盖掉",
                  self.notch.debugMessage.contains("贾维斯没开"))
            check("顺手把设置页开到了语音命令那一栏",
                  self.hub.debugFrame != nil)
            self.noteSession.cancel()
            self.noteSession.deleteCurrent()
            // 打开吧，后面那些正经用例要用。
            self.store.settings.jarvisModeEnabled = true
            self.store.settings.voiceCommandsEnabled = true
        }))

        // 走**真实按键**：右⌥ 按下必然先起一截「按住说话」，逗号到达时
        // 动作表要把它转成待命会话（ConvertHold）。这条分支只有真按键才走得到 ——
        // 直接调 toggle() 的话 hold 根本不存在。
        steps.append((0.5, {
            check("起始不抢占 esc/↩", self.hotkeys?.jarvisCountdown == false)
            emit("——— 功能开着时 ———")
            emit("→ 合成 ⌥,")
            Self.postRightOption(down: true)
        }))
        steps.append((0.4, {
            check("右⌥ 按下先起了一截按住说话（ConvertHold 的前提）",
                  self.recorder.isRecording)
            Self.postKeyWithRightOption(43)          // ,
        }))
        steps.append((0.5, {
            Self.postRightOption(down: false)
        }))
        steps.append((0.5, {
            emit("收到事件：\(self.selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            check("热键发出了 jarvisTogglePressed",
                  self.selfTestEvents.contains(.jarvisTogglePressed))
            check("待命起来了", self.jarvis.scanning && self.jarvis.owningRecorder)
            check("录音器真的开了", self.recorder.isRecording)
            check("刘海撑宽了（armed）", self.notch.debugArmed)
            check("刘海亮着", self.notch.isVisible)
            // 干跑：只算命不命中，不执行。
            emit("  干跑：\(self.jarvis.debugMatch("测试助手，\(marker)"))")
            check("干跑认得出关键词",
                  self.jarvis.debugMatch("测试助手，你好").contains("命中"))
            check("干跑对无关的话说未命中",
                  self.jarvis.debugMatch("今天天气不错") == "未命中")
        }))

        // 未命中：计数 +1，并且要把听到的原文说出来（否则分不清听错还是没听见）。
        steps.append((0.3, {
            let hit = self.jarvis.dispatch("今天天气不错")
            check("无关的话不命中", !hit)
            check("丢弃计数 +1", self.jarvis.discarded == 1)
            check("刘海回报了听到的原文（\(self.notch.debugMessage)）",
                  self.notch.debugMessage.contains("今天天气不错"))
        }))

        // 命中 → 抓选区（后台线程，要给它时间）→ 倒计时。
        steps.append((0.3, { _ = self.jarvis.dispatch("测试助手，\(marker)") }))
        steps.append((1.2, {
            emit("  \(self.jarvis.debugSnapshot)")
            check("进了倒计时", self.jarvis.debugPendingShell != nil)
            check("命令带上了口述内容",
                  self.jarvis.debugPendingShell?.contains(marker) == true)
            check("倒计时期间抢占 esc/↩", self.hotkeys?.jarvisCountdown == true)
            // esc 撤销 —— 决策点在执行**之前**。
            check("撤销成功", self.jarvis.undo())
        }))
        steps.append((0.3, {
            check("撤销后没有待执行命令", self.jarvis.debugPendingShell == nil)
            check("撤销后立刻还回 esc/↩", self.hotkeys?.jarvisCountdown == false)
            // 再来一次，这次让它真的跑完。
            _ = self.jarvis.dispatch("测试助手，\(marker)")
        }))

        // 倒计时 3 秒 + 终端冷启动。
        steps.append((JarvisTiming.undoCountdownSeconds + 4.0, {
            check("执行后 esc/↩ 已还回去", self.hotkeys?.jarvisCountdown == false)
            let text = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
            emit("  命令产物：\(outputPath) →「\(text.trimmingCharacters(in: .whitespacesAndNewlines))」")
            check("命令真的在终端里跑了", text.contains(marker))
            try? FileManager.default.removeItem(atPath: outputPath)
        }))

        // 收摊：⌥, 再按一次 = 整个待命会话结束。
        steps.append((0.3, {
            let message = self.jarvis.toggle()
            emit("⌥, → 「\(message ?? "")」")
            check("待命停了", !self.jarvis.scanning && !self.jarvis.owningRecorder)
            check("录音器也停了", !self.recorder.isRecording)
            check("刘海收了", !self.notch.isVisible)
            check("收摊后不再抢占 esc/↩", self.hotkeys?.jarvisCountdown == false)
        }))

        // ——— 共跑：扫描是 filter、落笔是 sink，两者正交（spec/01 §1）。
        // 这是历史上最容易写错的一块 —— 贾维斯以前是个 sink，两者永远互斥。
        steps.append((0.4, {
            emit("——— 共跑 ———")
            // 自动断句先关掉，这样「armed 无视这个开关」才是可观测的。
            self.store.settings.noteAutoSegment = false
            // 自动粘贴也关掉：开着的话每一段都会被插进当前前台窗口 ——
            // 既把「未粘贴」这个判据搅浑，也会往用户正在用的窗口里吐字。
            self.store.settings.noteAutoPaste = false
            check("落笔起来了", self.noteSession.start())
            let message = self.jarvis.toggle()
            emit("落笔录音中按 ⌥, → 「\(message ?? "")」")
            check("扫描叠加上去了（不是另起一摊）",
                  self.jarvis.scanning && !self.jarvis.owningRecorder)
            check("落笔照常在录", self.noteSession.isRecording)
            // A14：armed 时分段器无视「自动断句」开关 —— 段不闭合就永远扫不到命令。
            check("A14：armed 让落笔无视自动断句开关", self.noteSession.scanArmed)
        }))

        // 一段**没有**关键词的话：照常落进正文，不标指令。
        steps.append((0.3, {
            self.noteSession.debugInjectTranscript("今天讨论了三件事")
        }))
        steps.append((0.4, {
            let plain = self.noteSession.segments.last
            // 规则润色会补一个句号，所以判包含而不是相等。
            check("普通的一段照常落进正文（\(plain?.displayText ?? "")）",
                  plain?.displayText.hasPrefix("今天讨论了三件事") == true)
            check("普通的一段算未粘贴", plain?.pasted == false)
            // 一段命中关键词的话。
            self.noteSession.debugInjectTranscript("测试助手，\(marker)")
        }))
        steps.append((1.4, {
            let hit = self.noteSession.segments.last
            emit("  命中那段：「\(hit?.displayText ?? "")」pasted=\(hit?.pasted ?? false)")
            check("命中的那段**仍然**落进正文", hit?.displayText.contains(marker) == true)
            check("并且标成了指令（>> 前缀）", hit?.displayText.hasPrefix(">>") == true)
            check("预标已粘贴（命令跑了，没东西可粘）", hit?.pasted == true)
            // 「粘贴所有」只该看到那一段普通的话 —— 指令那段已经预标已粘贴。
            let unpasted = self.noteSession.segments.filter { !$0.pasted && $0.status == .done }
            check("「粘贴所有」只看得到那段普通的话（\(unpasted.count) 段）",
                  unpasted.count == 1 && unpasted[0].displayText.hasPrefix("今天讨论了三件事"))
            check("共跑时也进了倒计时", self.jarvis.debugPendingShell != nil)
            check("撤销它", self.jarvis.undo())
        }))

        // 落笔还开着时再按 ⌥,：只撤过滤器，录音**继续**。
        steps.append((0.4, {
            let message = self.jarvis.toggle()
            emit("再按 ⌥, → 「\(message ?? "")」")
            check("扫描撤了", !self.jarvis.scanning)
            check("落笔录音没被连累", self.noteSession.isRecording && self.recorder.isRecording)
            check("落笔的自动断句开关也还回去了", !self.noteSession.scanArmed)
            self.noteSession.cancel()
            self.noteSession.deleteCurrent()
            emit(failures == 0 ? "✅ 贾维斯通" : "❌ \(failures) 项不过")
            Log.flush()
            exit(failures == 0 ? 0 : 1)
        }))

        var delay: Double = 0
        for (gap, step) in steps {
            delay += gap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }

    // MARK: - ask 手势自测

    /// 「双击右⌥ 并按住」的自测。
    ///
    /// 手势本身（一击 ≤0.35s、间隔 ≤0.4s、再按住）只有真按键才走得到 ——
    /// matcher 的单测能覆盖判定，但覆盖不了「按下之后 App 到底进没进提问态」。
    ///
    /// ⚠️ 中间那一段「说话 → 转写」没法在自测里驱动（要真的对着麦克风说），
    /// 所以这里验两头：手势 → 提问态、以及 提问 → 答案回到刘海。
    private func runAskTest() {
        selfTest = true
        startHotkeys()
        store.readOnly = true
        store.settings.askModeEnabled = true

        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            emit("\(ok ? "  ✓" : "  ✗") \(label)")
            if !ok { failures += 1 }
        }

        emit("ask 可用=\(jarvis.askAvailable)（开关=\(store.settings.askModeEnabled) "
             + "claude=\(ClaudeCodeAgent.claudePath ?? "无")）")
        var steps: [(Double, () -> Void)] = []

        // 一击：按下 → 0.15s 松开（远短于 0.35s 的上限）。
        steps.append((0.4, {
            emit("→ 一击")
            Self.postRightOption(down: true)
        }))
        steps.append((0.15, { Self.postRightOption(down: false) }))
        // 间隔 0.2s（<0.4s）之后再按住 —— 这一次要被读成 ask。
        steps.append((0.2, {
            emit("→ 立刻再按住")
            Self.postRightOption(down: true)
        }))
        steps.append((0.6, {
            emit("收到事件：\(self.selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            check("手势被读成 ask（不是两次普通按住）",
                  self.selfTestEvents.contains(.askHoldPressed))
            check("录音起来了", self.recorder.isRecording)
            emit("  刘海：「\(self.notch.debugMessage)」")
            check("刘海说明这次是在提问", self.notch.debugMessage.contains("问克劳德"))
        }))
        steps.append((0.8, {
            emit("→ 松开")
            Self.postRightOption(down: false)
        }))
        steps.append((1.0, {
            check("松开发出了 askHoldReleased",
                  self.selfTestEvents.contains(.askHoldReleased))
            // ⚠️ 不能假设自测环境是安静的（实测踩过：风扇声就够把这一段
            // 判成有效语音，于是它真的被当成提问发出去了）。两种结局都对，
            // 错的是**默默消失**：要么说「没听到」，要么进提问流程。
            emit("  刘海：「\(self.notch.debugMessage)」")
            let quiet = self.notch.debugMessage.contains("没有听到声音")
                || self.notch.debugMessage.contains("太短")
            let heard = self.notch.debugMessage.contains("听你说完了")
                || self.notch.debugMessage.contains("克劳德")
                || self.jarvis.claude.busyKeyword != nil
            check("松开之后有交代（没听到 / 或进了提问流程）", quiet || heard)
        }))

        // 关掉开关 → 同一个手势退化成普通按住说话。
        steps.append((0.6, {
            emit("——— 关掉 ask 开关 ———")
            self.store.settings.askModeEnabled = false
            self.selfTestEvents.removeAll()
            Self.postRightOption(down: true)
        }))
        steps.append((0.15, { Self.postRightOption(down: false) }))
        steps.append((0.2, { Self.postRightOption(down: true) }))
        steps.append((0.6, {
            check("手势照样被识别（matcher 不受开关影响）",
                  self.selfTestEvents.contains(.askHoldPressed))
            emit("  刘海：「\(self.notch.debugMessage)」")
            check("但退化成了普通听写（刘海只有计时）",
                  !self.notch.debugMessage.contains("问克劳德"))
            Self.postRightOption(down: false)
        }))

        // 后半段：提问 → 答案回到刘海。走的是 ask 手势真正的出口。
        //
        // ⚠️ 先等上一轮落地再开始：上面那两次松开可能已经把一段噪声送出去了，
        // 不等它就会把**它的**回答当成这一问的答案（实测踩过）。
        steps.append((1.2, {
            emit("——— 提问 → 答案 ———")
            self.store.settings.askModeEnabled = true
            // 等两次：中间留出 3 秒，好让**迟到的那段转写**先浮出来 ——
            // 它可能还在本地模型里，第一次问「闲了吗」时看起来是闲的。
            self.waitForClaudeIdle(ticks: 0) { [self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
                    waitForClaudeIdle(ticks: 0) { [self] in
                        jarvis.claude.reset()      // 丢掉噪声起的那场会话
                        notch.show(state: .idle, message: "", title: "")
                        jarvis.askDirectly("只回答一个词：苹果。不要解释。")
                        waitForClaude(keyword: "提问", contains: "苹果", ticks: 0) { ok in
                            check("答案回到了刘海", ok)
                            emit(failures == 0 ? "✅ ask 手势通" : "❌ \(failures) 项不过")
                            Log.flush()
                            exit(failures == 0 ? 0 : 1)
                        }
                    }
                }
            }
        }))

        var delay: Double = 0
        for (gap, step) in steps {
            delay += gap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }

    // MARK: - Claude Code 助手自测

    private var claudeTestFailures = 0
    private var claudeTestFirstSession: String?

    /// 后台 Claude Code 助手的端到端自测。
    ///
    /// 只有一件事真正值得验：**第二句听得懂第一句**。所以第一轮让它记住一个词，
    /// 第二轮问它那个词是什么 —— 答对了，就说明 `--session-id` / `--resume`
    /// 那条会话链是真的接上了，而不是每句话都从零开始。
    ///
    /// 这一测会真的调用模型（几秒 + 几分钱），没有别的办法：会话延续是
    /// claude 那边的状态，本地怎么造都造不出来。
    private func runClaudeTest() {
        selfTest = true
        emit("环境：\(jarvis.claude.debugSnapshot)")
        emit("就绪判断：\(ClaudeCodeAgent.readiness)")
        guard ClaudeCodeAgent.claudePath != nil else {
            emit("❌ 没找到 claude 命令")
            Log.flush()
            exit(1)
        }

        store.readOnly = true          // 自测绝不能把用户的配置改了
        store.settings.voiceCommandsEnabled = true
        store.settings.jarvisModeEnabled = true
        store.settings.voiceCommands = [
            VoiceCommand(keyword: "测试助手", commandTemplate: "{text}",
                         runner: .claudeCode, enabled: true,
                         keywordPosition: .anywhere, continuousConversation: true)
        ]

        func check(_ label: String, _ ok: Bool) {
            emit("\(ok ? "  ✓" : "  ✗") \(label)")
            if !ok { claudeTestFailures += 1 }
        }

        let message = jarvis.toggle()
        emit("⌥, → 「\(message ?? "")」")
        check("待命起来了", jarvis.scanning)

        emit("→ 第一句：让它记住一个词")
        _ = jarvis.dispatch("测试助手，请只回答一个词：橘子。不要解释。")
        // 抓选区在后台线程，倒计时 3 秒 —— 等它进倒计时再按「立即执行」，
        // 免得自测白等。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            emit("  待执行：\(jarvis.debugPendingShell ?? "无")")
            check("第一句进了倒计时（新会话要过这道门）", jarvis.debugPendingShell != nil)
            check("提示词就是那句话本身",
                  jarvis.debugPendingShell?.contains("橘子") == true)
            _ = jarvis.runNow()          // ↩ 立即执行
            claudeTestFirstSession = jarvis.claude.sessionID(keyword: "测试助手")
            emit("  会话 id=\(claudeTestFirstSession ?? "无")")
            check("会话 id 是我们自己按上去的 uuid",
                  UUID(uuidString: claudeTestFirstSession ?? "") != nil)
            waitForClaude(keyword: "第一句", contains: "橘子", ticks: 0) { [self] ok in
                check("第一句答对了", ok)
                claudeSecondTurn(check: check)
            }
        }
    }

    /// 第二句：不再倒计时（这是对话不是新命令），并且必须接得住上下文。
    private func claudeSecondTurn(check: @escaping (String, Bool) -> Void) {
        emit("→ 第二句：问它刚才那个词是什么（考的是上下文）")
        notch.show(state: .idle, message: "", title: "")   // 清掉上一轮的字，免得误判
        _ = jarvis.dispatch("测试助手，我刚才让你回答的那个词是什么？只回答那个词。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            check("第二句**没有**再走倒计时（是对话，不是新命令）",
                  jarvis.debugPendingShell == nil)
            check("还是同一场会话",
                  jarvis.claude.sessionID(keyword: "测试助手") == claudeTestFirstSession)
            waitForClaude(keyword: "第二句", contains: "橘子", ticks: 0) { [self] ok in
                check("第二句记得第一句说过什么（--resume 真的接上了）", ok)
                claudeWebTurn(check: check)
            }
        }
    }

    /// 第三句：要联网才答得出来的问题。
    ///
    /// `-p` 是非交互的，需要确认的工具**弹不出确认框直接被拒**，模型只会回
    /// 一句「我没拿到网络访问权限」—— 用户看起来就像助手根本不能上网。
    /// 所以这一句必须真的抓到外部内容才算通过。
    /// 用 example.com 而不是股价：答案是恒定的，才断言得了。
    private func claudeWebTurn(check: @escaping (String, Bool) -> Void) {
        emit("→ 第三句：要联网才答得出来的问题")
        notch.show(state: .idle, message: "", title: "")
        _ = jarvis.dispatch("测试助手，用 WebFetch 打开 https://example.com，只回答页面标题四个字。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            waitForClaude(keyword: "第三句", contains: "Example Domain", ticks: 0) { [self] ok in
                check("联网的问题真的答上来了（不是「我没拿到权限」）", ok)
                check("没有反过来说自己没权限", !notch.debugMessage.contains("权限"))
                finishClaudeTest(check: check)
            }
        }
    }

    private func finishClaudeTest(check: @escaping (String, Bool) -> Void) {
        // tmux 里应该留着这场对话：两轮 = 两个窗口，跑完不销毁。
        let windows = Self.tmuxWindows()
        emit("tmux 窗口：\(windows.joined(separator: " | "))")
        check("每一轮都留在 tmux 里（\(windows.count) 个窗口）", windows.count == 3)
        let panes = windows.map { window in
            Self.tmux(["capture-pane", "-p", "-S", "-200",
                       "-t", "\(ClaudeCode.tmuxSession):\(window)"])
        }
        for (window, pane) in zip(windows, panes) {
            emit("  \(window)：\(pane.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(120))")
        }
        check("第一轮的问与答都在存档里",
              panes.contains { $0.contains("请只回答一个词") && $0.contains("橘子") })
        check("第二轮的问与答也在",
              panes.contains { $0.contains("我刚才让你回答") && $0.contains("橘子") })
        emit("环境：\(jarvis.claude.debugSnapshot)")

        // 收摊：把这场自测的 tmux 会话清掉，别留给用户。
        Self.tmux(["kill-session", "-t", ClaudeCode.tmuxSession])
        jarvis.stopStandby()
        emit(claudeTestFailures == 0 ? "✅ Claude Code 助手通（会话真的续上了）"
                                     : "❌ \(claudeTestFailures) 项不过")
        Log.flush()
        exit(claudeTestFailures == 0 ? 0 : 1)
    }

    /// 等到没有在飞的那一轮为止。
    private func waitForClaudeIdle(ticks: Int, completion: @escaping () -> Void) {
        guard jarvis.claude.busyKeyword != nil, ticks < 240 else {
            completion()
            return
        }
        if ticks == 0 { emit("  等上一轮落地（\(jarvis.claude.busyKeyword ?? "")）…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            waitForClaudeIdle(ticks: ticks + 1, completion: completion)
        }
    }

    /// 轮询刘海上的回答。模型可能要几十秒，写死等待时间只会测到「还没回来」。
    private func waitForClaude(keyword: String, contains: String, ticks: Int,
                               completion: @escaping (Bool) -> Void) {
        let text = notch.debugMessage
        let title = notch.debugTitle
        // 「还在想上一句」是拒绝，不是答案 —— 别把它当成这一问的结果。
        if title.contains("克劳德") && !title.contains("在想") && !title.contains("上一句") {
            emit("  \(keyword)回答（\(title)）：「\(text)」")
            completion(text.contains(contains))
            return
        }
        guard ticks < 240 else {                     // 0.5s × 240 = 120s
            emit("  \(keyword)超时（最后停在「\(title)」/「\(text)」）")
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            waitForClaude(keyword: keyword, contains: contains, ticks: ticks + 1,
                          completion: completion)
        }
    }

    @discardableResult
    private static func tmux(_ arguments: [String]) -> String {
        guard let tmux = ClaudeCodeAgent.tmuxPath else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func tmuxWindows() -> [String] {
        tmux(["list-windows", "-t", ClaudeCode.tmuxSession, "-F", "#{window_name}"])
            .split(separator: "\n").map(String.init)
    }

    // MARK: - 集成自测

    /// 本地 HTTP + `/api/notes` 的端到端自测。
    ///
    /// 用真的 `URLSession` 打真的 127.0.0.1:48765 —— 解析那一层已经有单测，
    /// 这里验的是接线：监听起没起来、两道门禁挡不挡得住、五条路由改的是不是
    /// 真的那份 `history.json`。
    private func runIntegrationTest() {
        selfTest = true
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            emit("\(ok ? "  ✓" : "  ✗") \(label)")
            if !ok { failures += 1 }
        }

        store.readOnly = true          // 自测绝不能把用户的配置改了
        store.settings.integrationApiEnabled = false
        let token = IntegrationStore.token()
        let base = "http://127.0.0.1:\(IntegrationStore.port)"

        func request(_ method: String, _ path: String, token: String? = nil,
                     body: [String: Any]? = nil) async -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = method
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body {
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: req) else {
                return (0, [:])
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (status, json)
        }

        Task { @MainActor in
            // 服务要一点时间才 ready。
            try? await Task.sleep(nanoseconds: 600_000_000)

            let (healthStatus, health) = await request("GET", "/health")
            emit("GET /health → \(healthStatus)")
            check("服务起来了", healthStatus == 200)
            check("/health 报了权限与快捷键", health["permissions"] != nil
                  && health["shortcuts"] != nil)

            // 门禁一：功能开关关着 → 403，连 token 对不对都不看。
            let (offStatus, _) = await request("GET", "/api/notes", token: token)
            check("开关关着时 403（\(offStatus)）", offStatus == 403)

            store.settings.integrationApiEnabled = true

            // 门禁二：没有 / 错误的 token → 401。
            let (noTokenStatus, _) = await request("GET", "/api/notes")
            check("没 token 时 401（\(noTokenStatus)）", noTokenStatus == 401)
            let (badStatus, _) = await request("GET", "/api/notes", token: String(token.dropLast()) + "0")
            check("错 token 时 401（\(badStatus)）", badStatus == 401)

            let before = self.noteStore.notes.count
            let (listStatus, list) = await request("GET", "/api/notes", token: token)
            check("列表 200（\(listStatus)）", listStatus == 200)
            check("列表条数对得上盘上的（\((list["notes"] as? [Any])?.count ?? -1) vs \(before)）",
                  (list["notes"] as? [Any])?.count == before)

            // 建
            let marker = "落音集成\(Int.random(in: 1000...9999))"
            let (createStatus, created) = await request(
                "POST", "/api/notes", token: token, body: ["text": marker, "title": "集成自测"])
            let id = ((created["note"] as? [String: Any])?["id"] as? String) ?? ""
            emit("POST /api/notes → \(createStatus) id=\(id)")
            check("建笔记 201", createStatus == 201)
            check("真的进了盘上的库", self.noteStore.note(id: id)?.finalText == marker)

            // 读
            let (readStatus, read) = await request("GET", "/api/notes/\(id)", token: token)
            check("读回来 200（\(readStatus)）", readStatus == 200)
            check("正文一致", (read["note"] as? [String: Any])?["text"] as? String == marker)

            // 改
            let (patchStatus, _) = await request("PATCH", "/api/notes/\(id)", token: token,
                                                 body: ["title": "改过的标题"])
            check("改 200（\(patchStatus)）", patchStatus == 200)
            check("标题真的改了", self.noteStore.note(id: id)?.title == "改过的标题")
            let (emptyPatch, _) = await request("PATCH", "/api/notes/\(id)", token: token,
                                                body: [:])
            check("什么都不给的 PATCH 是 400（\(emptyPatch)）", emptyPatch == 400)

            // 删
            let (deleteStatus, _) = await request("DELETE", "/api/notes/\(id)", token: token)
            check("删 200（\(deleteStatus)）", deleteStatus == 200)
            check("盘上真的没了", self.noteStore.note(id: id) == nil)
            let (goneStatus, _) = await request("GET", "/api/notes/\(id)", token: token)
            check("再读是 404（\(goneStatus)）", goneStatus == 404)
            let (unknownStatus, _) = await request("GET", "/api/settings", token: token)
            check("未知路由 404（\(unknownStatus)）", unknownStatus == 404)

            // token 是凭据：只有属主可读。
            let attributes = (try? FileManager.default.attributesOfItem(
                atPath: IntegrationStore.tokenPath.path)) ?? [:]
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check("token 文件是 0600（实际 \(String(mode, radix: 8))）", mode == 0o600)
            check("token 是 64 位十六进制", token.count == 64)

            // MCP 桥
            let script = IntegrationStore.exportMCPScript()
            let body = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            emit("MCP 桥 → \(script?.path ?? "无")")
            check("MCP 脚本落盘了", body.contains("list_notes") && body.contains("tools/call"))
            check("MCP 读的是原生版的 token 路径",
                  body.contains("app.inkfall.native/integration_token"))
            emit("注册命令：\(IntegrationStore.registerCommand)")

            // 真的把桥跑起来：node 起进程 → JSON-RPC 握手 → tools/call。
            // 只验「文件写出去了」证明不了编码助手接得上。
            if let script = script, let node = Self.nodePath() {
                let reply = Self.driveMCP(node: node, script: script)
                emit("MCP 应答：\(reply.prefix(160))")
                check("MCP 握手 + tools/list 通", reply.contains("list_notes"))
                check("MCP tools/call 真的读到了笔记", reply.contains("createdAtMs"))
            } else {
                emit("⚠️ 本机没有 node，跳过 MCP 桥的端到端验证")
            }

            // /debug 只读面
            let (debugStatus, debug) = await request("GET", "/debug/overlay/state")
            check("/debug 无需鉴权（\(debugStatus)）", debugStatus == 200)
            check("/debug 报了刘海几何", debug["capsule"] != nil)
            let (matchStatus, match) = await request(
                "GET", "/debug/jarvis/match?text=%E4%BB%8A%E5%A4%A9%E5%A4%A9%E6%B0%94")
            check("/debug/jarvis/match 干跑（\(matchStatus)）",
                  matchStatus == 200 && (match["result"] as? String) == "未命中")

            self.store.settings.integrationApiEnabled = false
            emit(failures == 0 ? "✅ 集成通" : "❌ \(failures) 项不过")
            Log.flush()
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// 本机的 node。App 是从 Finder / `open` 起的，PATH 里没有 homebrew。
    private static func nodePath() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 起一个真的 MCP 桥进程，走一遍 initialize → tools/list → tools/call。
    /// 一行一条 JSON-RPC（stdio 传输）。
    private static func driveMCP(node: String, script: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "起不来" }

        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        // 三条应答都回来之后桥仍然挂在 stdin 上等下一条 —— 给它一拍就收工。
        Thread.sleep(forTimeInterval: 2.0)
        try? input.fileHandleForWriting.close()
        process.terminate()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ") ?? ""
    }

    private func runNoteCutTest(wav: String) {
        selfTest = true
        let savedAutoSegment = noteSession.autoSegment
        noteSession.autoSegment = false
        startHotkeys()
        notePanel.show()
        guard noteSession.start() else {
            emit("起录失败")
            Log.flush()
            exit(1)
        }
        emit("会话开始（自动断句已关）")

        DispatchQueue.global(qos: .userInitiated).async {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [wav]
            try? player.run()
            player.waitUntilExit()
        }

        // 第一次单击：此刻**没有**待粘内容（一段都还没转完），所以这一键
        // 应当走「手动切段」那一支。
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [self] in
            emit("→ 第一次右⌥ 单击：待粘=\(noteSession.hasUnpasted) "
                 + "段数=\(noteSession.segments.count)")
            Self.postRightOption(down: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) { [self] in
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [self] in
            cutTestSegmentsAfterFirstTap = noteSession.segments.count
            emit("第一次单击之后：段数=\(cutTestSegmentsAfterFirstTap) "
                 + "落笔仍在录=\(noteSession.isRecording)")
        }

        // 等第一段真的转完 —— **不能用固定时刻**：首次推理要先加载模型，
        // 冷启动 7 秒以上，写死时间只会测到「还没转完」那一支。
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [self] in
            waitForUnpasted(ticks: 0, savedAutoSegment: savedAutoSegment)
        }
    }

    /// 轮询到「有待粘内容」为止，再发第二次单击验证粘贴支。
    private func waitForUnpasted(ticks: Int, savedAutoSegment: Bool) {
        guard noteSession.hasUnpasted || ticks >= 60 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                waitForUnpasted(ticks: ticks + 1, savedAutoSegment: savedAutoSegment)
            }
            return
        }
        cutTestSegmentsBeforeSecondTap = noteSession.segments.count
        emit("→ 第二次右⌥ 单击：待粘=\(noteSession.hasUnpasted) "
             + "段数=\(cutTestSegmentsBeforeSecondTap)（等了 \(Double(ticks) * 0.5)s）")
        Self.postRightOption(down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            noteSession.stop()
            waitForCutTest(ticks: 0, savedAutoSegment: savedAutoSegment)
        }
    }

    private var cutTestSegmentsAfterFirstTap = 0
    private var cutTestSegmentsBeforeSecondTap = 0

    private func waitForCutTest(ticks: Int, savedAutoSegment: Bool) {
        if noteSession.inFlight > 0, ticks < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                waitForCutTest(ticks: ticks + 1, savedAutoSegment: savedAutoSegment)
            }
            return
        }
        emit("收到事件：\(selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
        let tapped = selfTestEvents.contains(.longRecordingFlushTap)
        for segment in noteSession.segments {
            emit("  段 \(segment.id) [\(segment.status.rawValue)] "
                 + segment.displayText.replacingOccurrences(of: "\n", with: " ⏎ "))
        }
        // 分支一：没有待粘内容时，单击 = 切段。手动那一刀 + 停止收尾 ≥ 2 段。
        let cutBranch = tapped && cutTestSegmentsAfterFirstTap >= 1
        // 分支二：有待粘内容时，同一个键改成粘贴所有，**不再多切一段**。
        let pastedAll = noteSession.segments.filter(\.pasted).count
        let didNotCutAgain = noteSession.segments.count <= cutTestSegmentsBeforeSecondTap + 1
        emit("第一次单击后段数=\(cutTestSegmentsAfterFirstTap)（切段支）")
        emit("第二次单击前段数=\(cutTestSegmentsBeforeSecondTap) "
             + "最终段数=\(noteSession.segments.count) 已标记粘贴=\(pastedAll)（粘贴支）")
        let ok = cutBranch && pastedAll >= 1 && didNotCutAgain
        emit(ok ? "✅ 右⌥ 单击一键两用：无待粘→切段，有待粘→粘贴所有"
                : "❌ 一键两用没接通")

        noteSession.autoSegment = savedAutoSegment
        noteSession.deleteCurrent()
        Log.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(ok ? 0 : 1) }
    }

    /// 截图接线的自测。
    ///
    /// 「按了没反应」有两个成因，这里都要验到：
    /// 1. `screenshotFeatureEnabled` 默认关着 → `effectiveShortcuts` 把
    ///    ⌥; / ⌥' 两个槽**置空**，热键压根没绑上；
    /// 2. 面板按钮直连 `session.insertScreenshot`，没有笔记时静默失败。
    private func runScreenshotTest() {
        selfTest = true
        let keys = store.effectiveShortcuts
        emit("生效绑定：框选=「\(keys.selectScreenshotRegion.displayLabel)」"
             + " 整屏=「\(keys.captureScreenshot.displayLabel)」")
        emit("功能开关=\(store.settings.screenshotFeatureEnabled) "
             + "迁移标记=\(store.settings.screenshotDefaultMigrated) "
             + "屏幕录制授权=\(ScreenCapture.isAuthorized)")

        guard !keys.captureScreenshot.isEmpty else {
            emit("❌ 整屏截图没有绑定 —— 热键被功能开关置空了")
            Log.flush()
            exit(1)
        }
        guard ScreenCapture.isAuthorized else {
            emit("⚠️ 未授权屏幕录制，无法验证端到端")
            Log.flush()
            exit(1)
        }

        startHotkeys()
        // 没有面板、没有当前笔记 —— 正是「按了没反应」最容易复现的状态。
        emit("起始状态：面板可见=\(notePanel.isVisible) 当前笔记=\(noteSession.noteID ?? "无")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            emit("→ 合成 ⌥' （整屏截图）")
            Self.postRightOption(down: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            Self.postKeyWithRightOption(39)          // '
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [self] in
            emit("收到事件：\(selfTestEvents.map(String.init(describing:)).joined(separator: " → "))")
            let fired = selfTestEvents.contains(.captureScreenshotPressed)
            let noteID = noteSession.noteID
            let dir = noteID.map { NoteAttachments.directory(for: $0) }
            let files = dir.flatMap {
                try? FileManager.default.contentsOfDirectory(atPath: $0.path)
            } ?? []
            let inBody = noteSession.body.contains("![截图]")
            emit("热键触发=\(fired) 自动开了笔记=\(noteID ?? "无") "
                 + "面板可见=\(notePanel.isVisible) 图片文件=\(files.count) 正文含图片=\(inBody)")
            let ok = fired && noteID != nil && files.count == 1 && inBody
            emit(ok ? "✅ ⌥' 截图端到端通" : "❌ 截图没接通")
            noteSession.deleteCurrent()
            Log.flush()
            exit(ok ? 0 : 1)
        }
    }

    /// 右⌥ 按着时的一次普通键。修饰位（共享位 + 右侧设备位）必须带上，
    /// 否则 matcher 眼里那就是一个裸键。
    private static func postKeyWithRightOption(_ keycode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keycode, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: 0x80000 | 0x40)
            event.post(tap: .cghidEventTap)
        }
    }

    /// 编辑器按键的自测：⌘B 加粗、Tab 缩进、回车续列表、⌘Z 撤销。
    ///
    /// 发的是**真实的 CGEvent**，走完整条
    /// 「HID → WindowServer → 面板 sendEvent → handleKey → MarkdownEditing → 绑定回写」。
    /// 纯逻辑那一层已经有单测了，这里验的是接线：焦点拿不拿得到、拦截有没有
    /// 真的拦到、NSTextView 抢不抢得走 Tab 与回车、选区还原对不对。
    ///
    /// ⚠️ 每一步都必须用 `asyncAfter` 排队，**不能用 `RunLoop.run(until:)` 等**。
    /// 后者只跑 timer 与 input source，不从 AppKit 的事件队列取 NSEvent，
    /// 于是合成的鼠标/键盘事件一个都到不了面板（排查这个花了好几轮）。
    private struct KeyCase {
        let name: String
        let setup: (() -> Void)?
        let selection: NSRange
        let expect: String
        let post: () -> Void
    }
    private var keyCases: [KeyCase] = []
    private var keyCaseIndex = 0
    private var keyFailures = 0

    private func runNoteKeyTest() {
        selfTest = true
        notePanel.show()
        noteSession.openBlank()
        noteSession.draft = "甲乙丙"

        keyCases = [
            KeyCase(name: "⌘B 加粗选中的「乙」", setup: nil,
                    selection: NSRange(location: 1, length: 1), expect: "甲**乙**丙",
                    post: { Self.postKey(11, flags: .maskCommand) }),
            KeyCase(name: "⌘B 再按一次解开", setup: nil,
                    selection: NSRange(location: 3, length: 1), expect: "甲乙丙",
                    post: { Self.postKey(11, flags: .maskCommand) }),
            KeyCase(name: "回车续列表",
                    setup: { AppDelegate.shared?.noteSession.draft = "- 甲" },
                    selection: NSRange(location: 3, length: 0), expect: "- 甲\n- ",
                    post: { Self.postKey(36, flags: []) }),
            KeyCase(name: "空列表项上回车退出列表", setup: nil,
                    selection: NSRange(location: 6, length: 0), expect: "- 甲\n",
                    post: { Self.postKey(36, flags: []) }),
            KeyCase(name: "Tab 缩进",
                    setup: { AppDelegate.shared?.noteSession.draft = "- 甲" },
                    selection: NSRange(location: 1, length: 0), expect: "  - 甲",
                    post: { Self.postKey(48, flags: []) }),
            KeyCase(name: "⇧Tab 反缩进", setup: nil,
                    selection: NSRange(location: 1, length: 0), expect: "- 甲",
                    post: { Self.postKey(48, flags: .maskShift) }),
            KeyCase(name: "⌘Z 撤销回到缩进后的状态", setup: nil,
                    selection: NSRange(location: 0, length: 0), expect: "  - 甲",
                    post: { Self.postKey(6, flags: .maskCommand) }),
        ]

        // 等 SwiftUI 把编辑器画出来，再挪到主屏（合成点击要跨屏换算坐标，
        // 本机内置屏在外接屏下方，换算一错就点在没有窗口的地方）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            notePanel.debugMoveToMainScreen()
        }
        // 挪窗到 WindowServer 生效是异步的。挪完立刻点，点的是旧位置背后的
        // 那个窗口 —— 表现为「点完 App 反而失活了」。必须留出时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [self] in
            emit("点击前：\(notePanel.debugPanelState)")
            _ = notePanel.debugClickEditor()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { [self] in
            emit("点击后：\(notePanel.debugPanelState)")
            guard notePanel.debugEditorHasFocus else {
                emit("❌ 点进编辑器拿不到键盘焦点 —— 编辑模式没法打字")
                Log.flush()
                exit(1)
            }
            emit("✅ 点一下就能打字（面板成为键窗口，编辑器是第一响应者）")
            runNextKeyCase()
        }
    }

    private func runNextKeyCase() {
        guard keyCaseIndex < keyCases.count else {
            emit(keyFailures == 0 ? "✅ 编辑器按键全通" : "❌ \(keyFailures) 项没通")
            noteSession.deleteCurrent()
            Log.flush()
            exit(keyFailures == 0 ? 0 : 1)
        }
        let step = keyCases[keyCaseIndex]
        keyCaseIndex += 1

        step.setup?()
        noteSession.commitDraft()
        // 改完正文要等绑定落到 NSTextView 上，才谈得上设选区。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            notePanel.debugSetSelection(step.selection)
            step.post()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                let got = noteSession.draft
                let ok = got == step.expect
                if !ok { keyFailures += 1 }
                emit("\(ok ? "✅" : "❌") \(step.name)：「\(got.replacingOccurrences(of: "\n", with: "⏎"))」"
                     + (ok ? "" : "（期望「\(step.expect.replacingOccurrences(of: "\n", with: "⏎"))」）"))
                runNextKeyCase()
            }
        }
    }

    private static func postKey(_ keycode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keycode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// 编辑模式的自测。
    ///
    /// 盯四件事：正文落盘是**防抖**的（不是每敲一个字重写整库）、撤销栈
    /// 真的能回退、截图确实落成文件并进了正文、删除会连附件一起清掉。
    private func runNoteEditTest() {
        selfTest = true
        notePanel.show()
        noteSession.openBlank()
        let noteID = noteSession.noteID ?? "?"
        emit("新建空白笔记 \(noteID)")

        let historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/app.inkfall.native/history.json")
        func historyMTime() -> Date? {
            try? FileManager.default.attributesOfItem(
                atPath: historyURL.path)[.modificationDate] as? Date
        }

        // ——— 防抖：模拟逐字符输入，落盘次数必须远少于按键次数。
        let typed = "今天讨论了三件事"
        var writes = 0
        var lastSeen = historyMTime()
        for index in typed.indices {
            noteSession.draft = String(typed[typed.startIndex...index])
            noteSession.commitDraft()
            // 同步观察：不给 runloop 机会，防抖计时器就不会触发。
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let now = historyMTime()
            if now != lastSeen { writes += 1; lastSeen = now }
        }
        emit("逐字输入 \(typed.count) 次 → 期间落盘 \(writes) 次（防抖 0.6s）")

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        emit("防抖窗口过后正文=「\(noteSession.draft)」字数=\(noteSession.wordCount)")

        // ——— 撤销：连续打字合并成一步，⌘Z 应该整段退回。
        noteSession.draft = "今天讨论了三件事，第一件是排期"
        noteSession.commitDraft()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        noteSession.draft = "今天讨论了三件事，第一件是排期，第二件是预算"
        noteSession.commitDraft()
        emit("撤销前=「\(noteSession.draft)」canUndo=\(noteSession.canUndo)")
        noteSession.undo()
        emit("撤销一步=「\(noteSession.draft)」")
        noteSession.undo()
        emit("撤销两步=「\(noteSession.draft)」")
        noteSession.redo()
        emit("重做一步=「\(noteSession.draft)」")

        // ——— 中英混排的字数。
        noteSession.draft = "今天 review 了 pull request"
        noteSession.commitDraft()
        emit("中英混排「\(noteSession.draft)」→ \(noteSession.wordCount) 字"
             + "（中文「今天了」3 字 + 英文 review/pull/request 3 词 = 6）")

        // ——— 截图。整屏模式不需要交互，可以在自测里跑完。
        guard ScreenCapture.isAuthorized else {
            emit("⚠️ 未授权屏幕录制，跳过截图验证")
            finishNoteEditTest(noteID: noteID)
            return
        }
        noteSession.insertScreenshot(.fullScreen) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let dir = NoteAttachments.directory(for: noteID)
                let files = (try? FileManager.default
                    .contentsOfDirectory(atPath: dir.path)) ?? []
                let bytes = files.compactMap {
                    try? FileManager.default.attributesOfItem(
                        atPath: dir.appendingPathComponent($0).path)[.size] as? Int
                }.reduce(0, +)
                emit("截图落盘：\(files.count) 个文件 / \(bytes / 1024) KB")
                emit("正文尾部=「\(self.noteSession.draft.suffix(60))」")
            case .failure(let error):
                emit("❌ 截图失败 \(error.localizedDescription)")
            }
            self.finishNoteEditTest(noteID: noteID)
        }
    }

    private func finishNoteEditTest(noteID: String) {
        noteSession.flushPersist()
        let saved = noteStore.note(id: noteID)
        emit("盘上这篇：标题=「\(saved?.title ?? "无")」正文 \(saved?.finalText.count ?? 0) 字符")

        // ——— 删除必须连附件目录一起清掉。
        noteSession.deleteCurrent()
        let gone = noteStore.note(id: noteID) == nil
        let attachmentsGone = !FileManager.default.fileExists(
            atPath: NoteAttachments.directory(for: noteID).path)
        emit("删除后：笔记已移除=\(gone) 附件目录已移除=\(attachmentsGone)")
        emit(gone && attachmentsGone ? "✅ 编辑模式自测通过" : "❌ 删除没清干净")
        Log.flush()
        exit(gone && attachmentsGone ? 0 : 1)
    }

    /// 面板上的剪刀按钮。和两个快捷键走同一条路，反馈也一致。
    func cutNow() { reportCut(noteSession.flushNow()) }

    /// 双击预览里的某一段 → 把这一段插进起录时的那个窗口。
    func pasteSegment(_ id: UInt64) {
        guard noteSession.pasteSegment(id: id) else {
            flash(.cancelled, "这一段还没转好", seconds: 1.2)
            return
        }
        flash(.success, "已插入这一段", seconds: 1.2)
    }

    /// 手动切段的反馈。切了个空段却毫无提示，用户只会以为快捷键坏了。
    private func reportCut(_ outcome: NoteSessionController.CutOutcome) {
        switch outcome {
        case .submitted(let ms):
            noteFlash(.success, String(format: "已切段 · %.1fs", Double(ms) / 1000), seconds: 1.2)
        case .discarded:
            noteFlash(.cancelled, "这一段没有声音", seconds: 1.2)
        case .notRecording:
            flash(.cancelled, "未在录音", seconds: 1.2)
        }
    }

    // MARK: - 落笔的刘海

    /// 录音中的文案：计时 + 段数。
    private var noteNotchMessage: String {
        let time = String(format: "%02d:%02d",
                          noteSession.elapsedSeconds / 60, noteSession.elapsedSeconds % 60)
        let count = noteSession.segments.count
        // 不写「正在录音」—— 胶囊亮着本身就是那个意思。
        return count > 0 ? "\(time) · \(count) 段" : time
    }

    /// hover 条上的暂停/继续。
    func toggleNotePause() {
        let wasPaused = noteSession.isPaused
        guard noteSession.togglePause() else {
            // 继续失败只有一个原因：麦克风起不来（被别的 App 抢了、拔了）。
            // 静悄悄留在暂停态会让用户以为在录，而一个字都不会进来。
            if wasPaused { noteFlash(.error, "麦克风起不来", seconds: 1.8) }
            return
        }
        // 暂停不发 onRecordingChanged（发了刘海会被收走），所以这里要自己
        // 把胶囊推到位 —— 否则暂停之后刘海还停在最后一次的计时上。
        lastNoteNotchMessage = ""
        noteNotchHoldUntil = 0
        noteNotchNeedsRestore = true
        tickNoteNotch()
    }

    private func startNoteNotch() {
        hideTimer?.invalidate()
        lastNoteNotchMessage = ""
        noteNotchHoldUntil = 0
        noteNotchNeedsRestore = true
        notch.setHoverStripAvailable(true)
        noteNotchTimer?.invalidate()
        noteNotchTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in AppDelegate.shared?.tickNoteNotch() }
        }
        tickNoteNotch()
    }

    private func tickNoteNotch() {
        guard noteSession.isLive else { return }
        let paused = noteSession.isPaused
        // 暂停时电平必须归零。留着最后一帧的呼吸幅度，胶囊会看起来还在听。
        notch.setLevel(paused ? 0 : Double(recorder.level))
        // 瞬时提示（已切段 / 没有声音）的保护窗内不改文案。
        guard CFAbsoluteTimeGetCurrent() >= noteNotchHoldUntil else { return }
        let message = paused ? noteNotchMessage + " · 已暂停" : noteNotchMessage
        guard message != lastNoteNotchMessage || noteNotchNeedsRestore else { return }
        lastNoteNotchMessage = message
        noteNotchNeedsRestore = false
        notch.show(state: paused ? .notePaused : .recording, message: message, compact: true)
    }

    /// 录音中的瞬时提示。到点之后**回到落笔胶囊**，而不是像 `flash` 那样
    /// 把刘海整个收掉 —— 录音还在继续，刘海就不能消失。
    private func noteFlash(_ state: OverlayState, _ message: String, seconds: Double) {
        guard noteSession.isLive else {
            flash(state, message, seconds: seconds)
            return
        }
        hideTimer?.invalidate()
        notch.show(state: state, message: message, compact: true)
        noteNotchHoldUntil = CFAbsoluteTimeGetCurrent() + seconds
        noteNotchNeedsRestore = true
    }

    /// 录音停了：还在飞的段要继续显示「转写中」，都落地了才收。
    private func finishNoteNotch() {
        noteNotchTimer?.invalidate()
        noteNotchTimer = nil
        // ⚠️ 无条件收掉 hover 条，连同 click-through。会话没了还留着它，
        // 屏幕顶端会一直吃点击。
        notch.setHoverStripAvailable(false)
        notch.setLevel(0)
        let count = noteSession.segments.count
        guard count > 0 || noteSession.inFlight > 0 else {
            notch.hide()
            return
        }
        waitForNoteNotchDrain(ticks: 0)
    }

    private func waitForNoteNotchDrain(ticks: Int) {
        let inFlight = noteSession.inFlight
        guard inFlight > 0, ticks < 120 else {
            flash(.success, "已存 \(noteSession.segments.count) 段", seconds: 1.6)
            return
        }
        notch.show(state: .transcribing, message: "\(inFlight) 段转写中")
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in AppDelegate.shared?.waitForNoteNotchDrain(ticks: ticks + 1) }
        }
    }

    /// 截一张图插进当前笔记。
    ///
    /// 没有「当前笔记」时先开一篇 —— 截图本身就是一次记录动作，
    /// 让它因为「你还没开笔记」而失败是没道理的。
    func captureIntoNote(_ mode: ScreenCapture.Mode) {
        guard ScreenCapture.isAuthorized else {
            // 首次调用才会弹系统对话框，之后只能靠用户自己去设置里勾。
            ScreenCapture.requestAuthorization()
            permissions.request(.screenRecording)
            flash(.error, "需要屏幕录制权限", seconds: 2.5)
            return
        }
        if noteSession.noteID == nil {
            noteSession.openBlank()
        }
        notePanel.show()
        noteSession.insertScreenshot(mode) { [weak self] result in
            switch result {
            case .success:
                self?.flash(.success, "截图已插入笔记", seconds: 1.4)
            case .failure(let error):
                if case ScreenCapture.Failure.cancelled = error { return }
                self?.flash(.error, error.localizedDescription, seconds: 2.0)
            }
        }
    }

    /// 主页点一条笔记 → 在落笔面板里打开它。
    private func openNote(_ entry: HistoryEntry) {
        guard noteSession.open(entry) else {
            flash(.error, "正在录音，先停下来", seconds: 2.0)
            return
        }
        notePanel.show()
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

    /// 这一次「按住」是 ask 手势（问助手），不是听写。
    private var holdIsAsk = false
    /// ask 手势按下那一刻的选区。
    ///
    /// **必须在按下时抓**（spec/01 §3.1 并发抓选区）：用户是「选中一段 →
    /// 按住问」，等松开再抓，中间那几秒他多半已经点掉了选区。
    private var askSelection = ""

    private func beginHold() {
        guard !recorder.isRecording else { return }
        // 落笔会话开着时，右⌥ 按住不另起一段 —— 一个麦克风不能同时喂两条管线。
        // 暂停中也不行：麦克风虽然空着，但那次按住的转写会跑去抢刘海，
        // 而刘海这时正显示着「已暂停」等用户回来点继续。
        guard !noteSession.isLive else { return }
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
        hideTimer?.invalidate()
        // 和落笔一样走紧凑胶囊：只排一行计时。
        // 不写「正在录音」，也不写「松开结束」—— 手正按着那个键，
        // 用不着别人提醒它松开。
        lastHoldNotchSecond = -1
        notch.show(state: .recording,
                   message: holdIsAsk ? "问克劳德 00:00" : "00:00", compact: true)
        startLevelTicker()

        // ask：并发抓选区。用户是「选中一段 → 按住问」，等松开再抓就晚了。
        // ⌘C 那条路里全是 Thread.sleep，绝不能放主线程。
        guard holdIsAsk else { return }
        askSelection = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let selection = MacAutomation.captureSelection() ?? ""
            Task { @MainActor in AppDelegate.shared?.askSelection = selection }
        }
    }

    private func endHold() {
        // 只收自己起的那次录音。落笔会话接管之后这里必须是空操作 ——
        // 见 `holdOwnsRecorder` 的说明。
        guard holdOwnsRecorder else { return }
        holdOwnsRecorder = false
        // 这一次是不是提问，在这里定下来 —— 后面的转写是异步的，
        // 等它回来时下一次按住可能已经开始了。
        let asking = holdIsAsk
        holdIsAsk = false
        guard recorder.isRecording else { return }
        stopLevelTicker()
        guard let audio = try? recorder.stop() else {
            flash(.error, "录音结束失败", seconds: 2.0)
            return
        }
        // 太短 / 全静音的一段不进管线 —— 但**必须给反馈**。
        // 早先这里是直接 `notch.hide()`：用户说了一句、刘海一闪就没了，
        // 分不清是「没录上」还是「转写失败了」，只能干等。
        let verdict = RecordingSubmissionPolicy.default.verdict(for: audio)
        guard verdict == .submit else {
            Log.write("hotkey: 丢弃 \(verdict.rawValue) durationMs=\(audio.durationMs)")
            switch verdict {
            case .tooShort: flash(.cancelled, "太短了，没录上", seconds: 1.4)
            case .silent: flash(.cancelled, "没有听到声音", seconds: 1.4)
            case .submit: break
            }
            return
        }
        Log.write("hotkey: 采集完成 \(audio.data.count) 字节 / \(audio.durationMs) ms"
            + (asking ? "（提问）" : ""))
        if asking {
            transcribeAndAsk(audio)
        } else {
            transcribeAndInsert(audio)
        }
    }

    /// ask 手势的后半段：转写出问题 → 连同选区交给助手 → 显示答案（**不粘贴**）。
    private func transcribeAndAsk(_ audio: RecordedAudio) {
        notch.show(state: .transcribing, message: "听你说完了", title: "提问")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-ask-\(UUID().uuidString).wav")
        guard (try? audio.data.write(to: url)) != nil else {
            flash(.error, "写入临时文件失败", seconds: 2.0)
            return
        }
        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let request = LocalTranscriber.Request(
            wavURL: url, modelID: store.settings.selectedLocalModelId,
            language: policy.requested(locked: sessionLanguage),
            replacements: store.settings.transcriptionReplacements,
            diarize: false)

        Task { [transcriber] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await transcriber.transcribe(request)
                await MainActor.run { AppDelegate.shared?.deliverAsk(result.text) }
            } catch {
                Log.write("ask: 转写失败 \(error)")
                await MainActor.run {
                    AppDelegate.shared?.flash(.error, Self.short(error), seconds: 3.0)
                }
            }
        }
    }

    private func deliverAsk(_ transcript: String) {
        // 问题**不过润色**：那一层是给要粘出去的正文准备的，而这句话是给模型的。
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            return
        }
        let prompt = JarvisController.askCommand.prompt(
            spoken: question, selection: askSelection, clipboard: "")
        askSelection = ""
        Log.write("ask: 「\(question)」（带选区 \(prompt.count - question.count) 字）")
        jarvis.askDirectly(prompt)
    }

    // MARK: - 转写 → 加工 → 粘贴

    /// 本地模型跑完就把文字送回起录时的那个窗口。
    ///
    /// 云端路径（#10）还没接，所以这里只有 local 一条道；加工也只有不需要联网的
    /// 规则润色（#11 的九个预设要调 LLM）。
    private func transcribeAndInsert(_ audio: RecordedAudio) {
        let modelID = store.settings.selectedLocalModelId
        let name = LocalModels.definition(id: modelID)?.name ?? modelID
        let target = pasteTarget
        let diarizing = store.settings.noteWantsSpeakerLabels
            && LocalTranscriber.isDiarizationDownloaded
        notch.show(state: .transcribing,
                   message: diarizing ? "\(name) 转写中 · 分辨说话人" : "\(name) 转写中")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-take-\(UUID().uuidString).wav")
        do {
            try audio.data.write(to: url)
        } catch {
            flash(.error, "写入临时文件失败", seconds: 2.0)
            return
        }

        let policy = TranscriptionLanguagePolicy(settings: store.settings)
        let request = LocalTranscriber.Request(
            wavURL: url,
            modelID: modelID,
            language: policy.requested(locked: sessionLanguage),
            replacements: store.settings.transcriptionReplacements,
            // 「区分人物」是用户显式打开的 —— 开了就意味着这次录的是会议或访谈，
            // 那多花的那点时间是他要的。关着时绝不跑，单人听写跑分离只是白等。
            diarize: store.settings.noteWantsSpeakerLabels
                && LocalTranscriber.isDiarizationDownloaded)

        Task { [transcriber] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await transcriber.transcribe(request)
                await MainActor.run {
                    AppDelegate.shared?.lockSessionLanguage(result.language, policy: policy)
                    AppDelegate.shared?.deliver(result, into: target)
                }
            } catch {
                Log.write("transcribe: 失败 \(error)")
                await MainActor.run {
                    AppDelegate.shared?.flash(.error, Self.short(error), seconds: 3.0)
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

    private func deliver(_ result: LocalTranscriber.Result, into target: PasteTarget?) {
        // 规则润色（去口头禅、补标点）—— 纯本地，不需要联网。
        // 带说话人标签的结果原样放行：标签的排版是结构，不是待清理的噪声。
        let text = result.labeled ? result.text : BasicPolisher.polish(result.text)
        guard !text.isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            return
        }
        Log.write(String(format: "transcribe: %.2fs lang=%@ 说话人=%@ → %d 字",
                         result.elapsed, result.language ?? "?",
                         result.speakerCount.map(String.init) ?? "-", text.count))
        scheduleModelUnload()

        notch.show(state: .processing, message: "粘贴中")
        // ⚠️ 插入路径里是一连串 `Thread.sleep`（等剪贴板、等激活、等目标读完）。
        // 放主线程会把刘海动画连同整个 UI 冻住半秒以上，所以丢到后台队列。
        DispatchQueue.global(qos: .userInitiated).async {
            let route = MacAutomation.insert(text, into: target)
            DispatchQueue.main.async {
                Log.write("paste: route=\(route.rawValue) target=\(target?.appName ?? "无")")
                        let landed = target.map { "已粘回 \($0.appName)" } ?? "已复制到剪贴板"
                AppDelegate.shared?.flash(
                    .success, route == .clipboardOnly ? "已复制到剪贴板" : landed, seconds: 1.6)
            }
        }
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

    // MARK: - 本地模型

    @objc private func downloadLocalModel() {
        guard !modelDownloading else { return }
        let id = store.settings.selectedLocalModelId
        guard let model = LocalModels.definition(id: id) else { return }
        if LocalTranscriber.isDownloaded(model) {
            flash(.success, "\(model.name) 已就绪", seconds: 1.6)
            Task { [transcriber] in await transcriber.prewarm(modelID: id) }
            return
        }

        modelDownloading = true
        hideTimer?.invalidate()
        notch.show(state: .transcribing, message: "下载 \(model.name) \(model.sizeLabel)")
        Task {
            do {
                try await LocalTranscriber.download(model) { fraction in
                    Task { @MainActor in
                        AppDelegate.shared?.notch.show(
                            state: .transcribing,
                            message: "下载 \(model.name) \(Int(fraction * 100))%")
                    }
                }
                await MainActor.run {
                    AppDelegate.shared?.modelDownloading = false
                    AppDelegate.shared?.flash(.success, "\(model.name) 已就绪", seconds: 1.6)
                }
                await transcriber.prewarm(modelID: id)
            } catch {
                Log.write("model: 下载失败 \(error)")
                await MainActor.run {
                    AppDelegate.shared?.modelDownloading = false
                    AppDelegate.shared?.flash(.error, Self.short(error), seconds: 3.0)
                }
            }
        }
    }

    private func startLevelTicker() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in AppDelegate.shared?.pushLevel() }
        }
    }

    /// 按住说话期间刘海上的计时。**只在整秒变化时才写** ——
    /// 这个函数是 30 Hz 在跑的。
    private var lastHoldNotchSecond = -1

    private func pushLevel() {
        notch.setLevel(Double(recorder.level))
        guard holdOwnsRecorder, recorder.isRecording else { return }
        let whole = Int(recorder.takeDurationSeconds)
        guard whole != lastHoldNotchSecond else { return }
        lastHoldNotchSecond = whole
        // ⚠️ 提问态的前缀必须在这里也带上。这个函数 30 Hz 在跑，
        // `beginHold()` 写的那行「问克劳德 00:00」会在第一拍就被它盖掉 ——
        // 于是提问和普通听写在屏幕上长得一模一样（实测踩过）。
        let time = String(format: "%02d:%02d", whole / 60, whole % 60)
        notch.show(state: .recording,
                   message: holdIsAsk ? "问克劳德 \(time)" : time,
                   compact: true)
    }

    private func stopLevelTicker() {
        levelTimer?.invalidate()
        levelTimer = nil
        notch.setLevel(0)
    }

    private func flash(_ state: OverlayState, _ message: String, seconds: Double) {
        hideTimer?.invalidate()
        notch.show(state: state, message: message)
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in AppDelegate.shared?.notch.hide() }
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

extension AppDelegate: NSMenuDelegate {
    /// 每次展开都按磁盘现状重建模型菜单 —— 下载/删除完不刷新就会显示旧状态。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === modelMenuItem?.submenu else { return }
        modelMenuItem?.submenu = buildModelMenu()
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

    /// 交给监听器的配置：关掉截图功能时把那两个槽**置空**，而不是「匹配了但不处理」——
    /// 置空之后 ⌥; / ⌥' 会原样透传给其他 App，匹配后忽略则会被吞掉。
    var effectiveShortcuts: ShortcutsConfig {
        guard !settings.screenshotFeatureEnabled else { return shortcuts }
        var pruned = shortcuts
        pruned.selectScreenshotRegion = .empty
        pruned.captureScreenshot = .empty
        return pruned
    }

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
    /// 于是「跑了一遍自测」变成了「替用户打开了语音命令与贾维斯」。
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
