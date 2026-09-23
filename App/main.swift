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
    private var modelDownloading = false

    /// 会话内语言锁定：**两段判出同一种语言才锁**（见 `SessionLanguageLock`）。
    /// Whisper 对短句的自动检测经常判错，一句两个字的中文被当成英文，
    /// 输出就是一串音译垃圾 —— 而第一句恰恰最短最急，最不该由它定生死。
    private var languageLock = SessionLanguageLock()
    private var sessionLanguage: TranscriptionLanguage? { languageLock.locked }
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
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
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
            emit(ok ? "✅ 热键链路通" : "❌ 事件不完整")
            Log.flush()
            exit(ok ? 0 : 1)
        }
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
        submit(audio, tag: "hotkey")
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
        // 必须在起录时抓，不能等转写回来 —— 那时用户多半已经切走了。
        pasteTarget = PasteTarget.current()
        hideTimer?.invalidate()
        lastHoldNotchSecond = -1
        notch.show(state: .recording, message: "录音 00:00", compact: true)
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
        submit(audio, tag: "toggle")
    }

    /// 两个手势共用的尾巴：太短 / 全静音的一段不进管线 —— 但**必须给反馈**。
    /// 早先这里是直接 `notch.hide()`：用户说了一句、刘海一闪就没了，
    /// 分不清是「没录上」还是「转写失败了」，只能干等。
    private func submit(_ audio: RecordedAudio, tag: String) {
        let verdict = RecordingSubmissionPolicy.default.verdict(for: audio)
        guard verdict == .submit else {
            Log.write("\(tag): 丢弃 \(verdict.rawValue) durationMs=\(audio.durationMs)")
            switch verdict {
            case .tooShort: flash(.cancelled, "太短了，没录上", seconds: 1.4)
            case .silent: flash(.cancelled, "没有听到声音", seconds: 1.4)
            case .submit: break
            }
            return
        }
        Log.write("\(tag): 采集完成 \(audio.data.count) 字节 / \(audio.durationMs) ms")
        transcribeAndInsert(audio)
    }

    // MARK: - 转写 → 加工 → 粘贴

    /// 转写（云端或本地，见 `Transcriber`）→ 加工 → 送回起录时的那个窗口。
    /// 加工那一段九个预设都在，见 `PostProcessingCoordinator`。
    private func transcribeAndInsert(_ audio: RecordedAudio) {
        let durationMs = audio.durationMs
        let settings = store.settings
        let modelID = settings.selectedLocalModelId
        let name = Transcriber.label(for: settings)
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

        Task { [router] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let outcome = try await router.transcribe(audio: audio, local: request,
                                                          settings: settings, policy: policy)
                await MainActor.run {
                    AppDelegate.shared?.lockSessionLanguage(outcome.result.language, policy: policy)
                    AppDelegate.shared?.pendingTranscriptionNotice = outcome.notice
                    AppDelegate.shared?.deliver(outcome.result, into: target, durationMs: durationMs,
                                                route: outcome.route)
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

    private func deliver(_ result: LocalTranscriber.Result, into target: PasteTarget?,
                         durationMs: UInt64, route: String = "local") {
        guard !result.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            return
        }
        Log.write(String(format: "transcribe: %@ %.2fs lang=%@ 说话人=%@ → %d 字",
                         route, result.elapsed, result.language ?? "?",
                         result.speakerCount.map(String.init) ?? "-", result.text.count))
        scheduleModelUnload()

        // 加工可能要一次网络往返或 fork 一个 claude，所以整条尾巴是异步的。
        // 不加工的分支不会真的挂起，行为和以前一样立刻粘出去。
        Task { [processing, store] in
            let outcome = await processing.process(
                result.text,
                settings: store.settings,
                durationMs: durationMs,
                speakerLabeled: result.labeled,
                onRemoteStart: { [weak self] preset in
                    self?.notch.show(state: .processing, message: "\(preset.label) · 加工中")
                })
            self.insert(outcome, into: target)
        }
    }

    /// 加工结果 → 剪贴板/目标窗口。降级提示先说，再粘。
    private func insert(_ outcome: PostProcessingCoordinator.Outcome, into target: PasteTarget?) {
        let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flash(.cancelled, "没听清", seconds: 1.2)
            return
        }
        // ⚠️ 提示不能在这里 flash：紧接着的「粘贴中」和粘完的「已粘回 X」
        // 会在几十毫秒内把它盖掉，用户根本来不及看见。攒到粘贴结果那一刻
        // 一起说（见 `reportPaste`）。
        pendingProcessingNotice = outcome.notice.map { ($0, outcome.isProblem) }
            ?? pendingTranscriptionNotice.map { ($0, false) }
        pendingTranscriptionNotice = nil

        let options = PasteOptions(settings: store.settings)
        notch.show(state: .processing, message: options.autoPasteEnabled ? "粘贴中" : "复制中")
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
            emit("用法：--cloud-transcribe-test <wav> [--mode openai|groq|gemini|groqProxy|local]")
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
        if settings.transcriptionMode == .groqProxy {
            emit("落音云地址=\(TranscriptionAPI.proxyURL(settings: settings)?.absoluteString ?? "（没配）")")
        }

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
            settings: store.settings, durationMs: 9_000, transcript: sample, speakerLabeled: false)
        emit("裁决（9 s / \(sample.count) 字）：\(decision)")

        emit("")
        emit("原文：\(sample)")
        emit("本地 basic：\(BasicPolisher.polish(sample))")

        Task { [processing, store] in
            let started = CFAbsoluteTimeGetCurrent()
            let outcome = await processing.process(
                sample, settings: store.settings, durationMs: 9_000, speakerLabeled: false,
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

    /// 录音期间刘海上的计时。**只在整秒变化时才写** ——
    /// 这个函数是 30 Hz 在跑的。
    private var lastHoldNotchSecond = -1
    private func pushLevel() {
        notch.setLevel(Double(recorder.level))
        guard holdOwnsRecorder || toggleOwnsRecorder, recorder.isRecording else { return }
        let whole = Int(recorder.takeDurationSeconds)
        guard whole != lastHoldNotchSecond else { return }
        lastHoldNotchSecond = whole
        // ⚠️ 切换录音的前缀必须在这里也带上。这个函数 30 Hz 在跑，
        // `beginToggle()` 写的那行会在第一拍就被它盖掉。
        let time = String(format: "%02d:%02d", whole / 60, whole % 60)
        notch.show(state: .recording,
                   message: toggleOwnsRecorder ? "录音 \(time)" : time,
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
