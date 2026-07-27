import AppKit
import HighlightedTextEditor
import MarkdownUI
import SwiftUI
import InkfallCore

/// 落笔面板的 NSPanel。
///
/// ⚠️ **必须是自定义子类，不能用裸 NSPanel。**无边框窗口对
/// `canBecomeKeyWindow` 默认答 NO，而面板里有输入框（重命名标题）要收键盘。
/// 覆写成 YES；`becomesKeyOnlyIfNeeded` 仍然保证普通点击不抢键盘焦点。
final class InkfallNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 落笔 · 浮窗。
///
/// 非激活面板：点它**永远不抢走前台 App 的焦点** —— 否则「点一段插进 Xcode」
/// 这个动作本身会先把 Xcode 踢到后台。
@MainActor
final class NotePanelController {

    private var panel: InkfallNotePanel?
    let session: NoteSessionController

    init(session: NoteSessionController) {
        self.session = session
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
        if session.isRecording { session.stop() }
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var debugFrame: NSRect? { panel?.frame }
    /// 自测取证用：SwiftUI 的宿主视图，用来确认内容真的画出来了。
    var debugContentView: NSView? { panel?.contentView }

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = InkfallNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)

        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating                     // NSFloatingWindowLevel = 3
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.minSize = NSSize(width: 300, height: 320)

        let host = NSHostingView(rootView: NotePanelView(session: session))
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        // 首选屏右下角，离边一段距离。
        if let screen = ScreenInfo.preferred() {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 360 - 40, y: f.minY + 80))
        } else {
            p.center()
        }
        panel = p
    }
}

struct NotePanelView: View {
    @Bindable var session: NoteSessionController

    private let paperOnInk = Color(red: 0.945, green: 0.91, blue: 0.84)
    private let cinnabar = Color(red: 0.84, green: 0.35, blue: 0.29)

    var body: some View {
        VStack(spacing: 0) {
            titlebar
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
    }

    // MARK: - 标题栏

    private var titlebar: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRecording ? "waveform" : "square.and.pencil")
                .font(.system(size: 10))
                .foregroundStyle(session.isRecording ? cinnabar : paperOnInk.opacity(0.72))
                .frame(width: 19, height: 19)
                .background(session.isRecording ? cinnabar.opacity(0.24)
                                                : paperOnInk.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 5))
            Text(session.title.isEmpty ? "落笔" : session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(paperOnInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            // 录音中是预览、停下来是编辑器 —— 所以这个标签说的是**当前**状态，
            // 不是一个可切的开关。切换靠开始/停止录音。
            Text(session.isRecording ? "预览" : "编辑")
                .font(.system(size: 9.5))
                .foregroundStyle(paperOnInk.opacity(0.5))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        if session.isRecording {
            preview
        } else {
            editor
        }
    }

    /// 录音中：只读的 markdown 预览。正文是段落合成的，用户此刻不该编辑它 ——
    /// 下一段随时会追加进来，光标会被挤走。
    private var preview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.body.isEmpty && session.inFlight == 0 {
                        emptyGuide
                    } else {
                        Markdown(session.body)
                            .markdownTheme(.inkDark)
                            .textSelection(.enabled)
                    }
                    if session.inFlight > 0 {
                        Text("\(session.inFlight) 段转写中…")
                            .font(.system(size: 10.5))
                            .italic()
                            .foregroundStyle(paperOnInk.opacity(0.42))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            }
            // 新段落落进来就滚到底 —— 边说边看的时候不该还要自己拖。
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
                view.backgroundColor = .clear
                view.drawsBackground = false
                // ⚠️ 光关掉 NSTextView 的背景不够：滚动视图自己还垫了一层
                // NSVisualEffectView，在深墨面板上会透出一片浅色。
                view.enclosingScrollView?.drawsBackground = false
                view.enclosingScrollView?.backgroundColor = .clear
                view.insertionPointColor = NSColor(cinnabar)
                view.textColor = NSColor(paperOnInk)
                view.font = .systemFont(ofSize: 11.5)
                view.textContainerInset = NSSize(width: 8, height: 9)
            }
            .onChange(of: session.draft) { _, _ in session.commitDraft() }
            .frame(maxHeight: .infinity)
    }

    private var emptyGuide: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(["按 ⌥Space 开始 / 停止录音（⌥, 也可以）",
                     "说话自然停顿约 1.3 秒自动切一段",
                     "停下来之后这里变成 markdown 编辑器",
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
            Text(session.isRecording ? timeText : "--:--")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(cinnabar)
            Spacer()
            if session.isRecording {
                recButton("scissors") { session.flushNow() }
                recButton("stop.fill", destructive: true) { session.stop() }
            } else {
                recButton("record.circle") { _ = session.start() }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(cinnabar.opacity(session.isRecording ? 0.08 : 0.0))
    }

    private var timeText: String {
        String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
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
