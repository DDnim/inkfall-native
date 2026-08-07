import AppKit
import HighlightedTextEditor
import MarkdownUI
import SwiftUI
import InkfallCore

/// 落笔面板的 NSPanel。
///
/// ⚠️ **必须是自定义子类，不能用裸 NSPanel。**无边框窗口对
/// `canBecomeKeyWindow` 默认答 NO，而面板里有输入框（标题、正文编辑器）
/// 要收键盘。覆写成 YES；`becomesKeyOnlyIfNeeded` 仍然保证普通点击不抢焦点。
final class InkfallNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 编辑器的按键拦截。返回 true 表示已经处理，事件不再往下传。
    ///
    /// 走 `sendEvent` 而不是 `performKeyEquivalent`：Tab 与回车不是
    /// key equivalent，而且 NSTextView 一旦成为第一响应者就会自己吃掉它们。
    /// 这里是唯一能在它之前插手的位置。
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

/// 落笔 · 浮窗。
///
/// 非激活面板：点它**永远不抢走前台 App 的焦点** —— 否则「点一段插进 Xcode」
/// 这个动作本身会先把 Xcode 踢到后台。
@MainActor
final class NotePanelController {

    private var panel: InkfallNotePanel?
    let session: NoteSessionController

    /// 编辑器的 NSTextView。按键处理要拿它的选区，导出/查找也要用。
    /// 由 `NotePanelView` 的 introspect 回填。
    fileprivate weak var textView: NSTextView?

    /// 全篇转译。宿主注入 —— 面板只管点，任务归它管。
    private let fullTranscribe: FullTranscribeController

    init(session: NoteSessionController, fullTranscribe: FullTranscribeController) {
        self.session = session
        self.fullTranscribe = fullTranscribe
    }

    // MARK: - 全篇转译

    /// 现在跑不了的原因；`nil` = 能跑。
    func fullTranscribeBlocker() -> FullTranscribeController.Failure? {
        guard let noteID = session.noteID else { return .noAudio }
        return fullTranscribe.blocker(for: noteID)
    }

    var isFullTranscribing: Bool { fullTranscribe.isBusy }

    func startFullTranscribe() {
        guard let noteID = session.noteID else { return }
        do {
            try fullTranscribe.start(noteID: noteID)
        } catch {
            let alert = NSAlert()
            alert.messageText = "跑不了全篇转译"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        ensurePanel()
        // orderFrontRegardless 而不是 makeKeyAndOrderFront：保住用户的前台窗口。
        panel?.orderFrontRegardless()
    }

    func hide() {
        // 没有面板就没有笔记录音（隐私规则）：关面板必须真的把录音停掉，
        // 停下来的这一段照常转写并落进笔记，不丢数据。
        if session.isLive { session.stop() }
        // 正文可能还压着一次防抖没写盘，关窗之前必须写出去。
        session.flushPersist()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 自测取证用：往正文编辑器里**真的点一下**。
    ///
    /// 不能用 `makeFirstResponder` 代替。面板是 `becomesKeyOnlyIfNeeded`，
    /// 只有当用户点进一个需要键盘的控件时它才会成为键窗口 —— 程序调
    /// `makeKeyAndOrderFront` 不算数。所以「点进去能不能打字」这件事
    /// 只能靠合成一次真实鼠标点击来验，那也正是用户的实际路径。
    @discardableResult
    func debugClickEditor() -> Bool {
        guard let panel, let view = textView else { return false }
        let inWindow = view.convert(view.bounds, to: nil)
        let inScreen = panel.convertToScreen(inWindow)
        // CGEvent 的坐标原点在左上角，NSScreen 在左下角，Y 要翻。
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: inScreen.midX, y: height - inScreen.midY)

        let source = CGEventSource(stateID: .hidSystemState)
        for (type, isDown) in [(CGEventType.leftMouseDown, true), (.leftMouseUp, false)] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point,
                                      mouseButton: .left) else { return false }
            event.post(tap: .cghidEventTap)
            _ = isDown
        }
        return true
    }

    /// 自测专用：把面板挪到主屏中央。合成鼠标点击要跨屏换算坐标，
    /// 而本机内置屏在外接屏下方（负 Y），换算一错就点在没有窗口的地方。
    func debugMoveToMainScreen() {
        guard let panel, let main = NSScreen.screens.first else { return }
        let f = main.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                     y: f.midY - panel.frame.height / 2))
    }

    /// 点完之后再摆选区。点击本身会把光标放在点中的位置上。
    func debugSetSelection(_ range: NSRange) {
        textView?.setSelectedRange(range)
    }

    var debugEditorHasFocus: Bool {
        guard let panel, let view = textView else { return false }
        // 光是第一响应者不够 —— 面板不是键窗口的话按键根本送不进来。
        // 对照实验：becomesKeyOnlyIfNeeded = true 时第一响应者确实是
        // NSTextView，但键窗口是 false，七项按键测试全废。
        guard panel.isKeyWindow else { return false }
        // NSTextView 的第一响应者身份可能落在它的 field editor 上。
        var responder = panel.firstResponder
        while let current = responder {
            if current === view { return true }
            responder = (current as? NSView)?.superview
        }
        return false
    }

    var debugSelection: NSRange? { textView?.selectedRange() }

    var debugPanelState: String {
        let responder = panel?.firstResponder.map { String(describing: type(of: $0)) } ?? "无"
        return "App激活=\(NSApp.isActive) 面板可见=\(isVisible) "
            + "键窗口=\(panel?.isKeyWindow ?? false) 第一响应者=\(responder)"
    }

    /// 直接把事件投进 App 的事件队列，绕开 WindowServer 的窗口路由。
    /// 用来把「拦截逻辑对不对」和「事件送没送到这个 App」两件事分开验。
    func debugPostDirect(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
    }
    var debugFrame: NSRect? { panel?.frame }

    /// 取证用：`screencapture -l <窗口号>` 只截这一个窗口。
    /// 整屏截图在多窗口/多实例的真实桌面上极易被别人盖住，而面板是
    /// 非激活窗口，抢不到最前面 —— 只截自己这一扇才是确定的。
    var debugWindowNumber: Int? { panel?.windowNumber }
    /// 自测取证用：SwiftUI 的宿主视图，用来确认内容真的画出来了。
    var debugContentView: NSView? { panel?.contentView }

    /// 会议笔记开着时是两栏，面板要宽一倍 —— 380 分成两半的话
    /// 两边都只剩一条缝，谁都读不了。
    static let singleColumnWidth: CGFloat = 380
    static let twoColumnWidth: CGFloat = 760

    private var preferredWidth: CGFloat {
        session.meeting.isEnabled ? Self.twoColumnWidth : Self.singleColumnWidth
    }

    /// 两栏时的下限也要跟着抬：否则用户能把两栏面板拖回 320 宽，
    /// 那正是这个宽度想避开的两条缝。
    private var minimumWidth: CGFloat {
        session.meeting.isEnabled ? 620 : 320
    }

    /// 会议笔记开关翻了：面板宽度跟着变。面板在那儿开着的时候翻开关，
    /// 不改宽度的话右栏要么挤成一条缝，要么关掉之后留下一大片空白。
    ///
    /// **钉住右边缘往左长**：面板默认停在屏幕右下角，从右边长出去会顶到屏幕外。
    func syncMeetingWidth() {
        guard let panel else { return }
        let target = preferredWidth
        panel.minSize = NSSize(width: minimumWidth, height: 340)
        guard abs(panel.frame.width - target) > 0.5 else { return }

        var frame = panel.frame
        frame.origin.x = frame.maxX - target
        frame.size.width = target
        if let screen = panel.screen ?? ScreenInfo.preferred() {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - target }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        // 录音中不做动画：`setFrame(animate:)` 会**阻塞主线程**跑完整个动画，
        // 而主线程上正跑着 30 Hz 的面板刷新与段落落地。
        panel.setFrame(frame, display: true, animate: !session.isLive)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let width = preferredWidth
        let p = InkfallNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)

        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating                     // NSFloatingWindowLevel = 3
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.minSize = NSSize(width: minimumWidth, height: 340)
        p.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        let host = NSHostingView(rootView: NotePanelView(session: session, controller: self))
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        // 首选屏右下角，离边一段距离。
        if let screen = ScreenInfo.preferred() {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - width - 40, y: f.minY + 80))
        } else {
            p.center()
        }
        panel = p
        syncFocusPolicy()
    }

    /// 键盘焦点策略随模式走。
    ///
    /// ⚠️ `becomesKeyOnlyIfNeeded = true` 时这个面板**根本拿不到键盘焦点** ——
    /// 点进正文编辑器不会让面板成为键窗口，编辑模式等于只能看不能打字
    /// （合成鼠标点击实测：点击落在面板内，键窗口仍然是 false）。
    ///
    /// 但也不能一律关掉：录音中点面板不该把前台 App 的键盘焦点抢走
    /// （将来「点一段插进 Xcode」正是靠这个）。所以按模式切：
    /// - 编辑模式：允许成为键窗口。用户点进来就是要打字。
    /// - 录音模式：不抢焦点。正文此刻是只读预览，没有打字的需求。
    ///
    /// 面板始终是 `.nonactivatingPanel`，两种模式下 App 都不会被激活到前台。
    func syncFocusPolicy() {
        panel?.becomesKeyOnlyIfNeeded = session.isLive
    }

    // MARK: - 编辑器按键

    /// 只在正文编辑器是第一响应者时插手，别的地方（标题输入框）原样放行。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let view = textView, panel?.firstResponder === view,
              !session.isLive else { return false }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": return wrap("**")
            case "i": return wrap("*")
            case "z":
                shift ? session.redo() : session.undo()
                // 撤销是整篇替换，光标位置无从还原，放到末尾。
                restoreCaretToEnd()
                return true
            case "f": return showFind()
            default: return false
            }
        }

        switch event.keyCode {
        case 48:                                        // Tab
            return applyEdit(shift
                ? MarkdownEditing.outdent(session.draft, selection: view.selectedRange())
                : MarkdownEditing.indent(session.draft, selection: view.selectedRange()))
        case 36, 76:                                    // Return / 小键盘 Enter
            return continueList(in: view)
        default:
            return false
        }
    }

    private func wrap(_ marker: String) -> Bool {
        guard let view = textView else { return false }
        return applyEdit(MarkdownEditing.toggleWrap(session.draft,
                                                    selection: view.selectedRange(),
                                                    marker: marker))
    }

    /// 回车续列表。不在列表里就返回 false，让回车照常插入换行。
    private func continueList(in view: NSTextView) -> Bool {
        let caret = view.selectedRange().location
        let line = MarkdownEditing.line(in: session.draft, at: caret)
        guard let prefix = MarkdownEditing.listContinuation(forLine: line) else { return false }

        let chars = Array(session.draft)
        var lineStart = min(caret, chars.count)
        while lineStart > 0, chars[lineStart - 1] != "\n" { lineStart -= 1 }

        if prefix.isEmpty {
            // 空列表项上回车 = 退出列表：把这一行的标记整个清掉。
            let lineEnd = min(lineStart + line.count, chars.count)
            let new = String(chars[0..<lineStart]) + String(chars[lineEnd...])
            return applyEdit(.init(text: new, selection: NSRange(location: lineStart, length: 0)))
        }

        let head = String(chars[0..<min(caret, chars.count)])
        let tail = String(chars[min(caret, chars.count)...])
        let inserted = "\n" + prefix
        return applyEdit(.init(text: head + inserted + tail,
                               selection: NSRange(location: caret + inserted.count, length: 0)))
    }

    private func applyEdit(_ edit: MarkdownEditing.Edit) -> Bool {
        session.draft = edit.text
        session.commitDraft()
        // 绑定回写要等 SwiftUI 走完一轮才落到 NSTextView 上，
        // 这一拍之内设选区会被随后的整体替换冲掉。
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.textView else { return }
            let length = (view.string as NSString).length
            let location = min(edit.selection.location, length)
            let span = min(edit.selection.length, length - location)
            view.setSelectedRange(NSRange(location: location, length: span))
        }
        return true
    }

    private func restoreCaretToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.textView else { return }
            let length = (view.string as NSString).length
            view.setSelectedRange(NSRange(location: length, length: 0))
        }
    }

    /// NSTextView 自带查找栏。这个 App 没有主菜单里的「查找」项，
    /// ⌘F 到不了响应链，只能手工触发。
    @discardableResult
    func showFind() -> Bool {
        guard let view = textView else { return false }
        // performTextFinderAction 从 sender 的 tag 里读要执行哪个动作，
        // 所以必须造一个带 tag 的 sender，不能传 nil。
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        panel?.makeKeyAndOrderFront(nil)      // 查找栏要能收键盘输入
        view.performTextFinderAction(item)
        return true
    }

    // MARK: - 导出

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.body, forType: .string)
    }

    func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (session.title.isEmpty ? "落笔" : session.title) + ".md"
        panel.canCreateDirectories = true
        // 保存面板是模态的，非激活面板拉不起来它 —— 必须先激活 App。
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.body.write(to: url, atomically: true, encoding: .utf8)
            Log.write("note: 已导出 \(url.lastPathComponent)")
        } catch {
            Log.write("note: 导出失败 \(error)")
        }
    }

    func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "删除这篇笔记？"
        alert.informativeText = "正文与其中的截图都会被删掉，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.deleteCurrent()
    }

    /// 面板上的截图按钮。
    ///
    /// ⚠️ 走宿主的统一入口，**不能直接调 `session.insertScreenshot`** ——
    /// 那条路没有权限检查，也没有「当前没有笔记就先开一篇」的兜底，
    /// noteID 为 nil 时会直接静默失败（按了没反应就是这么来的）。
    func captureScreenshot(_ mode: ScreenCapture.Mode) {
        AppDelegate.shared?.captureIntoNote(mode)
    }
}

struct NotePanelView: View {
    @Bindable var session: NoteSessionController
    let controller: NotePanelController

    private let paperOnInk = Color(red: 0.945, green: 0.91, blue: 0.84)
    private let cinnabar = Color(red: 0.84, green: 0.35, blue: 0.29)

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Divider().overlay(paperOnInk.opacity(0.1))
            switches
            Divider().overlay(paperOnInk.opacity(0.1))
            content
            Divider().overlay(paperOnInk.opacity(0.1))
            recbar
        }
        .background(
            LinearGradient(colors: [Color(red: 0.086, green: 0.067, blue: 0.047),
                                    Color(red: 0.039, green: 0.031, blue: 0.02)],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: session.isLive) { _, _ in controller.syncFocusPolicy() }
        // 设置页那个开关翻的是同一个值，所以从哪边翻都会走到这里。
        .onChange(of: session.meetingNotes) { _, _ in controller.syncMeetingWidth() }
    }

    // MARK: - 标题栏

    private var titlebar: some View {
        HStack(spacing: 7) {
            Image(systemName: session.isRecording ? "waveform" : "square.and.pencil")
                .font(.system(size: 10))
                .foregroundStyle(session.isRecording ? cinnabar : paperOnInk.opacity(0.72))
                .frame(width: 19, height: 19)
                .background(session.isRecording ? cinnabar.opacity(0.24)
                                                : paperOnInk.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 5))

            // 录音中标题不可改：正文都还没定，改名没有意义，
            // 而一个能收键盘的输入框会跟「面板不抢焦点」打架。
            if session.isLive {
                Text(session.title.isEmpty ? "落笔" : session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(paperOnInk)
                    .lineLimit(1)
            } else {
                TextField("未命名", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(paperOnInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            toolbar
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            toolButton("camera.viewfinder", "截图插入正文（⌥;）") {
                controller.captureScreenshot(.region)
            }
            if !session.isLive {
                toolButton("magnifyingglass", "查找 / 替换（⌘F）") { controller.showFind() }
                toolButton("doc.on.doc", "复制全文") { controller.copyAll() }
                toolButton("square.and.arrow.up", "导出 .md") { controller.exportMarkdown() }
                toolButton("trash", "删除这篇", destructive: true) {
                    controller.confirmDelete()
                }
            }
        }
    }

    private func toolButton(_ symbol: String, _ hint: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(destructive ? Color(red: 0.94, green: 0.65, blue: 0.61)
                                             : paperOnInk.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    // MARK: - 四个开关

    /// 自动分段 / 区分人物 / 自动粘贴 / 会议笔记。
    ///
    /// 放在面板里而不是只留在设置页：这几件事是**逐场**决定的 —— 这次是会议就
    /// 开区分人物和会议笔记，这次是往编辑器里口述就开自动粘贴。要为此翻一次
    /// 设置窗口，就等于没有这个开关。它们写的仍然是同一份 `AppSettings`，
    /// 和设置页里的那几行是同一个值。
    private var switches: some View {
        HStack(spacing: 6) {
            chip("scissors", "自动分段",
                 on: session.autoSegment,
                 hint: "停顿约 1.3 秒自动切一段") { session.autoSegment = $0 }
            chip("person.2.wave2", "区分人物",
                 on: session.diarize,
                 enabled: session.diarizationReady,
                 hint: session.diarizationReady
                     ? "给每段标注是谁在说" : "需要先在设置里下载分离模型") {
                session.diarize = $0
            }
            chip("text.insert", "自动粘贴",
                 on: session.autoPaste,
                 hint: "每段转写完立刻插进起录时的那个窗口") { session.autoPaste = $0 }
            chip("list.bullet.rectangle", "会议笔记",
                 on: session.meetingNotes,
                 hint: "边录边在右栏整理议题/决定/待办，另存为一条笔记（Beta，"
                     + "每轮整理都要一次模型往返）") {
                session.meetingNotes = $0
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func chip(_ symbol: String, _ label: String, on: Bool,
                      enabled: Bool = true, hint: String,
                      set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            HStack(spacing: 3.5) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(!enabled ? paperOnInk.opacity(0.25)
                             : on ? cinnabar : paperOnInk.opacity(0.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(on ? cinnabar.opacity(0.16) : paperOnInk.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(on ? cinnabar.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(hint)
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        // 会议笔记（beta）开着时，正文与笔记**并排** —— 左边是转写的原样，
        // 右边是不断长出来的会议笔记。刻意不做成切换标签：这个功能的全部
        // 意义就是让人一眼看到「说了什么」与「记下了什么」的差别。
        if session.meeting.isEnabled {
            HStack(spacing: 0) {
                transcriptColumn
                Divider().overlay(paperOnInk.opacity(0.12))
                meetingColumn
            }
        } else {
            transcriptColumn
        }
    }

    @ViewBuilder
    private var transcriptColumn: some View {
        // 暂停也走预览：正文仍然是段落合成的，继续录音时新段会追加进来，
        // 这时候让用户编辑 `draft` 只会被 `syncDraft()` 悄悄冲掉。
        if session.isLive {
            preview
        } else {
            editor
        }
    }

    /// 右栏：自动会议笔记（beta）。
    private var meetingColumn: some View {
        let meeting = session.meeting
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("会议笔记")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(paperOnInk.opacity(0.7))
                Text("BETA")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(cinnabar)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(cinnabar.opacity(0.16), in: Capsule())
                Spacer(minLength: 4)
                // 「在整理」必须看得见：这一路比转写慢一个量级，不说破的话
                // 用户会以为它坏了。
                if meeting.isWorking {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                if meeting.note.isEmpty {
                    Text(meeting.isWorking ? "正在整理第一份笔记…"
                                           : "说满 \(MeetingNoteScheduler.firstBatchCharacters) 字后开始整理")
                        .font(.system(size: 10.5))
                        .foregroundStyle(paperOnInk.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                } else {
                    // 逐行渲染，而不是把整篇丢给一个 Markdown 视图 ——
                    // 只有这样才能给「最近两轮改动」的那几行单独上底色。
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(meetingLines(meeting.note).enumerated()), id: \.offset) {
                            _, line in
                            meetingLine(line, meeting: meeting)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                }
            }
            // 图例：不说明的话两种底色只是两团颜色，没人猜得到含义。
            if !meeting.latestChangedLines.isEmpty {
                HStack(spacing: 8) {
                    legendDot(meetingLatestTint, "最新一轮")
                    if !meeting.previousChangedLines.isEmpty {
                        legendDot(meetingPreviousTint, "上一轮")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            if let notice = meeting.notice {
                Text(notice)
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.amber)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 录音中：只读的 markdown 预览。正文是段落合成的，用户此刻不该编辑它 ——
    /// 下一段随时会追加进来，光标会被挤走。
    /// 录音中：**按段**渲染的 markdown 预览。
    ///
    /// 刻意不是「把全文拼成一个 Markdown 视图」——
    /// 1. 每段就是一个独立的 markdown 块，段与段之间天然是段落边界，
    ///    不依赖拼接时那两个换行能不能被正确解析；
    /// 2. 双击某一段要能把**那一段**粘出去，那就必须有逐段的命中区域。
    private var preview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if session.segments.isEmpty {
                        emptyGuide
                    }
                    ForEach(session.segments) { segment in
                        SegmentBlock(segment: segment,
                                     paste: { AppDelegate.shared?.pasteSegment(segment.id) })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
            }
            // 新段落落进来就滚到底 —— 边说边看的时候不该还要自己拖。
            .onChange(of: session.segments.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.body) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 停下来之后：markdown 编辑器（正则高亮，NSTextView 底子）。
    private var editor: some View {
        HighlightedTextEditor(text: $session.draft, highlightRules: .markdown)
            .introspect { editor in
                let view = editor.textView
                // 按键处理与导出都要拿它。
                controller.textView = view
                view.backgroundColor = .clear
                view.drawsBackground = false
                // ⚠️ 关掉 NSTextView 的背景**远远不够**，会得到一整片白。
                // HighlightedTextEditor 的 ScrollableTextView 建出来就是
                // `scrollView.drawsBackground = true` +
                // `textView.backgroundColor = .textBackgroundColor`，
                // 而后者在浅色外观下就是纯白。三层都要按掉：
                // NSScrollView、它内部的 NSClipView、以及 NSTextView 自己。
                //
                // 另外**不要走 `view.enclosingScrollView`** —— 库是在
                // `viewWillDraw()` 里才把 textView 挂进 scrollView 的，
                // 首次 introspect 发生在那之前，取到的是 nil，这几行会静默失效。
                // introspect 的 `Internals` 本来就直接给了 scrollView。
                let scroll = editor.scrollView
                scroll?.drawsBackground = false
                scroll?.backgroundColor = .clear
                scroll?.contentView.drawsBackground = false
                scroll?.contentView.backgroundColor = .clear
                // 兜底：即使将来某一层又自己画背景，深色外观下也是深的，不是白的。
                scroll?.appearance = NSAppearance(named: .darkAqua)
                view.appearance = NSAppearance(named: .darkAqua)
                view.insertionPointColor = NSColor(cinnabar)
                view.textColor = NSColor(paperOnInk)
                view.font = .systemFont(ofSize: 11.5)
                view.textContainerInset = NSSize(width: 8, height: 9)
                // ⌘F 的查找栏。用查找栏而不是老的查找面板 —— 面板是独立窗口，
                // 会把非激活的落笔面板挤到后面去。
                view.usesFindBar = true
                view.isIncrementalSearchingEnabled = true
            }
            .onChange(of: session.draft) { _, _ in session.commitDraft() }
            .frame(maxHeight: .infinity)
    }

    private var emptyGuide: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(["按 ⌥Space 开始 / 停止录音（⌥, 也可以）",
                     "说话自然停顿约 1.3 秒自动切一段",
                     "停下来之后这里变成 markdown 编辑器",
                     "⌥; 框选截图，直接插进正文",
                     "每次开始录音都会新建一篇笔记"], id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(paperOnInk.opacity(0.42))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 录音条

    private var recbar: some View {
        HStack(spacing: 8) {
            Text(session.isLive ? timeText : "--:--")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                // 暂停时计时是冻住的，颜色也要跟着退下去 ——
                // 一个亮着朱砂却不走的数字读起来像卡死。
                .foregroundStyle(session.isPaused ? paperOnInk.opacity(0.45) : cinnabar)
            Text("\(session.wordCount) 字")
                .font(.system(size: 10))
                .foregroundStyle(paperOnInk.opacity(0.4))
            if session.isPaused {
                Text("已暂停")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(paperOnInk.opacity(0.55))
            }
            // 共跑指示：贾维斯 armed 时每段既留下又扫描。必须看得见 ——
            // 「待命」单独跑时承诺的是「什么都不留」，这里正好相反，
            // 而两者用的是同一个 ⌥,。
            if session.scanArmed {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 9))
                    Text("待命").font(.system(size: 9.5, weight: .medium))
                }
                // 面板是墨底的，用刘海那套固定色板里的青，不跟随系统明暗。
                .foregroundStyle(Color(red: 0.44, green: 0.75, blue: 0.70))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color(red: 0.44, green: 0.75, blue: 0.70).opacity(0.14),
                            in: Capsule())
            }
            Spacer()
            // 停下来之后才出现，排在录音那几个按钮**左边**：录音期间它没有意义
            // （音频还在往里加），而停下来的那一刻正是「这篇的人物对不上，
            // 重跑一次」最自然的时机。
            if !session.isLive {
                fullTranscribeButton
            }
            if session.isLive {
                if session.isRecording {
                    recButton("scissors") { AppDelegate.shared?.cutNow() }
                }
                recButton(session.isPaused ? "play.fill" : "pause.fill") {
                    AppDelegate.shared?.toggleNotePause()
                }
                recButton("stop.fill", destructive: true) { session.stop() }
            } else {
                recButton("record.circle") { _ = session.start() }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(cinnabar.opacity(session.isRecording ? 0.08 : 0.0))
    }

    private var timeText: String {
        String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
    }

    /// 全篇转译。
    ///
    /// 汉字按钮而不是图标：这一档是**破坏性程度最低、但解释成本最高**的操作
    /// —— 「重跑一次说话人分离」没有任何图标说得清，而旁边三个（分段/暂停/
    /// 停止）都是无需解释的通用符号。
    ///
    /// 跑不了的时候**不隐藏，而是灰掉并把原因写进 tooltip** ——
    /// 「按钮消失了」是最难自查的一类 UI：用户根本不知道有这个功能，
    /// 更不知道差什么。
    @ViewBuilder private var fullTranscribeButton: some View {
        let blocker = controller.fullTranscribeBlocker()
        let running = controller.isFullTranscribing
        Button {
            controller.startFullTranscribe()
        } label: {
            Text(running ? "转译中…" : "全篇转译")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(running ? cinnabar : paperOnInk.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(paperOnInk.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(paperOnInk.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(blocker != nil || running)
        .opacity(blocker == nil ? 1 : 0.35)
        .help(running ? "整篇正在重跑，完成后会新建一条笔记"
                      : (blocker?.errorDescription
                         ?? "整篇重跑一次说话人分离 —— 分段跑时每段各聚各的，"
                            + "人物对不上。结果另存为新笔记，原文不动"))
    }

    /// 最近一轮 = 朱砂（这套界面的强调色）；上一轮 = 青（刘海那套固定色板里的
    /// 另一支）。两支在墨底上都够分辨，而且都不跟随系统明暗。
    private var meetingLatestTint: Color { cinnabar }
    private var meetingPreviousTint: Color { Color(red: 0.44, green: 0.75, blue: 0.70) }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.45))
                .frame(width: 8, height: 8)
            Text(label).font(.system(size: 9)).foregroundStyle(paperOnInk.opacity(0.45))
        }
    }

    /// 一行会议笔记：缩进深度 + 剃掉缩进的正文。
    ///
    /// 两件事必须分开存：缩进是**层级**（渲染成左边距），而正文是**身份**
    /// —— `MeetingNoteDiff.changedLines` 存的就是剃过缩进的行，高亮要拿它去查。
    private struct MeetingLine {
        let depth: Int
        let text: String
    }

    /// 会议笔记按行切。空行丢掉 —— 逐行渲染时它们只会变成一堆空隙。
    ///
    /// ⚠️ 这里**不能**把缩进连同两端空白一起剃掉了事：逐行渲染时每行都是独立的
    /// 一个 Markdown 块，二级列表全靠这个缩进画出来，剃了就全塌成一级。
    private func meetingLines(_ note: String) -> [MeetingLine] {
        note.components(separatedBy: .newlines).compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            // 提示词要求两个空格一级，但模型不一定听话；到二级为止，
            // 再深的缩进一律按二级画 —— 面板只有一半宽，画不下更深的层级。
            return MeetingLine(depth: min(indentColumns(of: raw) / 2, 2), text: text)
        }
    }

    /// 缩进宽度。制表符按 4 列算 —— 模型偶尔会吐 tab 而不是空格。
    private func indentColumns(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == "\t" { columns += 4 } else if character == " " { columns += 1 }
            else { break }
        }
        return columns
    }

    @ViewBuilder
    private func meetingLine(_ line: MeetingLine, meeting: MeetingNoteController) -> some View {
        let tint: Color? = meeting.latestChangedLines.contains(line.text) ? meetingLatestTint
            : (meeting.previousChangedLines.contains(line.text) ? meetingPreviousTint : nil)
        Markdown(line.text)
            .markdownTheme(.inkDark)
            .markdownSoftBreakMode(.lineBreak)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint?.opacity(0.16) ?? .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                // 左侧一条竖线：底色在深色主题上容易被当成选中态，
                // 加一条边才读得出「这是新增的」。
                if let tint {
                    RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.7))
                        .frame(width: 2)
                }
            }
            // 跳变要有过渡 —— 隔十几秒整块内容突然换掉，没有动画很像是出错了。
            .animation(.easeOut(duration: 0.35), value: tint != nil)
            // 缩进画在最外层：底色与左侧那条竖线要跟着一起缩，
            // 只缩文字的话高亮块仍然顶在左边，看不出层级。
            .padding(.leading, CGFloat(line.depth) * 13)
    }

    private func recButton(_ symbol: String, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(destructive ? Color(red: 0.94, green: 0.65, blue: 0.61)
                                             : paperOnInk)
                .frame(width: 22, height: 22)
                .background(destructive ? Color(red: 0.7, green: 0.23, blue: 0.18).opacity(0.4)
                                        : paperOnInk.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// 本地文件图片。
///
/// 截图落在 App 容器里，正文引用的是 `file://` 绝对路径。MarkdownUI 默认的
/// 图片加载走网络栈，本地文件直接从磁盘读更省事也更可靠。
struct LocalFileImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let url {
                // 非本地图片交回默认实现（网络图）。
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) }
                    placeholder: { Color.clear.frame(height: 1) }
            }
        }
    }
}

extension ImageProvider where Self == LocalFileImageProvider {
    static var localFile: Self { LocalFileImageProvider() }
}

extension MarkdownUI.Theme {
    /// 面板是深墨底，`.basic` 与 `.gitHub` 都是给浅底做的，所以从 `.basic`
    /// 派生并只覆盖颜色与字号。
    ///
    /// ⚠️ 不碰 `.heading1 { }` 这类 block-style 闭包 —— 它们要求返回
    /// `some View`，而 `View` 的修饰符是 MainActor 隔离的，Swift 6 的严格并发
    /// 不让把结果交给一个 nonisolated 闭包。标题的相对字号 `.basic` 已经有了。
    static var inkDark: MarkdownUI.Theme {
        let paper = Color(red: 0.945, green: 0.91, blue: 0.84)
        return MarkdownUI.Theme.basic
            .text {
                ForegroundColor(paper)
                FontSize(11.5)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(10.5)
                ForegroundColor(Color(red: 0.5, green: 0.82, blue: 0.75))
            }
            .link { ForegroundColor(Color(red: 0.84, green: 0.35, blue: 0.29)) }
            .strong { FontWeight(.semibold) }
    }
}

/// 预览里的一段。
///
/// 双击把这一段插进起录时的那个窗口（spec/03 的「点一段插进 Xcode」）。
///
/// ⚠️ 这里**刻意不开 `.textSelection(.enabled)`**。开了之后双击会被
/// 文本选择接管（选中一个词），`onTapGesture(count: 2)` 永远收不到。
/// 要选文字可以停止录音进编辑模式，或者用工具栏的「复制全文」。
private struct SegmentBlock: View {
    let segment: NoteSessionSegment
    let paste: () -> Void

    @State private var hovering = false

    private let paperOnInk = Color(red: 0.945, green: 0.91, blue: 0.84)
    private let cinnabar = Color(red: 0.84, green: 0.35, blue: 0.29)

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            content
            Spacer(minLength: 0)
            // 已经粘出去过的段留个淡记号，免得手动补粘时重复。
            if segment.pasted {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8))
                    .foregroundStyle(paperOnInk.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering && segment.status == .done
                    ? paperOnInk.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if segment.status == .done { paste() } }
        .help(segment.status == .done ? "双击把这一段插进目标窗口" : "")
    }

    @ViewBuilder
    private var content: some View {
        switch segment.status {
        case .processing:
            Text("转写中…")
                .font(.system(size: 10.5)).italic()
                .foregroundStyle(paperOnInk.opacity(0.4))
        case .failed:
            // 原因必须写出来：失败的成因至少有四种，而它们要用户做的事
            // 完全不同（去关「区分人物」？还是根本不用管？）。
            VStack(alignment: .leading, spacing: 2) {
                Text("这一段没转出来")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(red: 0.94, green: 0.65, blue: 0.61).opacity(0.85))
                if let reason = segment.failureReason {
                    Text(reason)
                        .font(.system(size: 9.5))
                        .foregroundStyle(paperOnInk.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .done:
            Markdown(segment.displayText)
                .markdownTheme(.inkDark)
                .markdownImageProvider(.localFile)
                // ⚠️ 必须是 .lineBreak。CommonMark 里单个 `\n` 是 soft break，
                // 默认渲染成**一个空格** —— 说话人标签用的正是单换行分行
                // （要的是换行不是分段），不改这个开关的话
                // 「说话人 1：… 说话人 2：…」会全糊在一行里。
                .markdownSoftBreakMode(.lineBreak)
        }
    }
}
