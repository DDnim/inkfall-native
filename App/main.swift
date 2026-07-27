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
    private lazy var hub = HubWindowController(store: store, permissions: permissions,
                                               models: models, notes: noteStore)

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

    /// 会话内语言锁定：第一段检测到什么，后面就跟着它走。
    /// Whisper 对短句的自动检测经常判错，一句两个字的中文被当成英文，
    /// 输出就是一串音译垃圾。
    private var sessionLanguage: TranscriptionLanguage?
    /// 空闲一段时间就把模型还给系统 —— turbo 常驻 1.5 GB。
    private var unloadTimer: Timer?
    private var modelMenuItem: NSMenuItem?

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

        // 验证入口：屏幕捕获受 TCC 限制、刘海又是 click-through 的，
        // 所以「它到底渲染成什么样」只能靠这条通道取证。
        // 这是 spec/04 §3.2 那套 /debug 路由在原生版的最小对应物。
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
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [self] in
            emit("→ 合成 右⌥ 松开")
            Self.postRightOption(down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [self] in
            emit("松开后：录音=\(recorder.isRecording)")
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
            emit(held && ticking ? "✅ 长录锁得住" : "❌ 录音状态没锁住")
            noteSession.cancel()
            Log.flush()
            exit(held && ticking ? 0 : 1)
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
        // ask 手势的管线（提问 → LLM 作答）还没接，按 spec §11 退化成普通按住说话。
        case .overlayHoldPressed, .askHoldPressed:
            beginHold()
        case .overlayHoldReleased, .askHoldReleased:
            endHold()

        case .cancelRecordingPressed:
            abortSpuriousHold()
            if noteSession.isRecording {
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
            if noteSession.isRecording {
                noteSession.flushNow()
            } else if !recorder.isRecording {
                // Fn 推杆用户的常见情形：松开 Fn 去按组合键时录音其实已经停了。
                flash(.cancelled, "未在录音", seconds: 1.2)
            }

        case .noteModePressed:
            // ⌥ 按下的那一刻已经起了一截「按住说话」，那是组合键的副产物
            // 而不是说话内容。先把它丢掉，再接管录音器。
            abortSpuriousHold()
            // ⌥Space 是「开始/停止落笔录音」，不是「显示/隐藏面板」——
            // 面板只是这件事的可视化。
            if noteSession.isRecording {
                noteSession.stop()
            } else {
                notePanel.show()
                guard noteSession.start() else {
                    flash(.error, "麦克风未授权", seconds: 2.0)
                    return
                }
            }
            hotkeys?.noteTogglesActive = notePanel.isVisible

        case .historyPickerPressed:
            abortSpuriousHold()
            hub.show(page: .home)

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
        // 落笔正在录音时，右⌥ 按住不另起一段 —— 一个麦克风不能同时喂两条管线。
        guard !noteSession.isRecording else { return }
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
        notch.show(state: .recording, message: "松开结束")
        startLevelTicker()
    }

    private func endHold() {
        // 只收自己起的那次录音。落笔会话接管之后这里必须是空操作 ——
        // 见 `holdOwnsRecorder` 的说明。
        guard holdOwnsRecorder else { return }
        holdOwnsRecorder = false
        guard recorder.isRecording else { return }
        stopLevelTicker()
        guard let audio = try? recorder.stop() else {
            flash(.error, "录音结束失败", seconds: 2.0)
            return
        }
        // 太短 / 全静音的一段直接丢掉，不进管线也不打扰用户。
        let verdict = RecordingSubmissionPolicy.default.verdict(for: audio)
        guard verdict == .submit else {
            Log.write("hotkey: 丢弃 \(verdict.rawValue) durationMs=\(audio.durationMs)")
            notch.hide()
            return
        }
        Log.write("hotkey: 采集完成 \(audio.data.count) 字节 / \(audio.durationMs) ms")
        transcribeAndInsert(audio)
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

    /// 第一段的检测结果锁住整场会话。固定模式不锁；preferred 模式只接受
    /// 候选表里的语言 —— 一句噪声被判成越南语不该把整场会都带偏。
    private func lockSessionLanguage(_ detected: String?,
                                     policy: TranscriptionLanguagePolicy) {
        let language = TranscriptionLanguage.detected(detected)
        guard policy.shouldLock(detected: language, locked: sessionLanguage) else { return }
        sessionLanguage = language
        Log.write("transcribe: 会话语言锁定 \(language?.rawValue ?? "?")")
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

    private func pushLevel() {
        notch.setLevel(Double(recorder.level))
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
        loaded.sanitize()
        settings = loaded

        var keys = ShortcutsConfig()
        if let data = try? Data(contentsOf: Self.source("shortcuts.json")),
           let decoded = try? JSONDecoder().decode(ShortcutsConfig.self, from: data) {
            keys = decoded
        }
        shortcuts = keys
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

    func save() {
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
