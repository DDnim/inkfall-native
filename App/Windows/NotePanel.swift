import AppKit
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
    let model = NotePanelModel()

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        ensurePanel()
        // orderFrontRegardless 而不是 makeKeyAndOrderFront：保住用户的前台窗口。
        panel?.orderFrontRegardless()
    }

    func hide() {
        // 关闭面板要停掉笔记录音 —— 没有面板就没有笔记录音（隐私规则）。
        // 录音器接上之后这里要真的停。
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var debugFrame: NSRect? { panel?.frame }

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

        let host = NSHostingView(rootView: NotePanelView(model: model))
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

@MainActor
@Observable
final class NotePanelModel {
    var recording = false
    var paused = false
    var autoSegment = true
    var autoPaste = false
    var noteTitle = ""
    var segments: [NoteSessionSegment] = []
    var pasteTargetName: String?
}

struct NotePanelView: View {
    @Bindable var model: NotePanelModel

    private let paperOnInk = Color(red: 0.945, green: 0.91, blue: 0.84)
    private let cinnabar = Color(red: 0.84, green: 0.35, blue: 0.29)

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Divider().overlay(paperOnInk.opacity(0.1))
            body_
            Divider().overlay(paperOnInk.opacity(0.1))
            pills
            recbar
        }
        .background(
            LinearGradient(colors: [Color(red: 0.086, green: 0.067, blue: 0.047),
                                    Color(red: 0.039, green: 0.031, blue: 0.02)],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            icon("arrow.up.to.line")            // ⤒ 收进刘海
            icon("ellipsis")
            Text(model.noteTitle.isEmpty ? "落笔 · 笔记模式" : model.noteTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(paperOnInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            icon("pin.fill", on: true)
            icon("xmark")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private func icon(_ name: String, on: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 10))
            .foregroundStyle(on ? cinnabar : paperOnInk.opacity(0.72))
            .frame(width: 19, height: 19)
            .background(on ? cinnabar.opacity(0.24) : paperOnInk.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 5))
    }

    private var body_: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if model.segments.isEmpty {
                    // 空态是多行使用指引 —— 面板第一次打开时，用户还不知道
                    // 「说话会自己落成一段」这件事。
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(emptyGuide, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11))
                                .foregroundStyle(paperOnInk.opacity(0.42))
                        }
                    }
                    .padding(.top, 8)
                } else {
                    ForEach(model.segments) { segment in
                        segmentBlock(segment)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyGuide: [String] {
        ["按 ⌥Space 开始 / 停止录音（⌥, 也可以）",
         "说话自然停顿约 1.3 秒自动切段",
         "双击或 ⌘单击一段，插入到目标窗口",
         "单击右⌥：粘贴所有新内容"]
    }

    private func segmentBlock(_ segment: NoteSessionSegment) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(segment.pasted ? paperOnInk.opacity(0.2) : cinnabar.opacity(0.55))
                .frame(width: 2)
            Text(segment.status == .processing ? "转写中…" : segment.displayText)
                .font(.system(size: 11))
                .italic(segment.status == .processing)
                .foregroundStyle(paperOnInk.opacity(segment.status == .processing ? 0.42 : 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(paperOnInk.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        // 已粘贴的降到 44% 透明但**不消失** —— 还能再次粘贴。
        .opacity(segment.pasted ? 0.44 : 1)
    }

    /// 会话开关：按触碰频率分组，这四个是常改的，所以常驻。
    private var pills: some View {
        HStack(spacing: 5) {
            pill("doc.on.clipboard", "自动粘贴", on: model.autoPaste)
            pill("scissors", "自动断句", on: model.autoSegment)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
    }

    private func pill(_ symbol: String, _ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(label).font(.system(size: 9.5))
        }
        .foregroundStyle(on ? Color(red: 0.5, green: 0.82, blue: 0.75) : paperOnInk.opacity(0.6))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(on ? Color(red: 0.16, green: 0.5, blue: 0.45).opacity(0.3)
                       : paperOnInk.opacity(0.07),
                    in: Capsule())
    }

    /// 录音条只在录音**或暂停**时出现（暂停保持在屏上但灰化、计时冻结）。
    private var recbar: some View {
        HStack(spacing: 8) {
            Text(model.recording ? "00:00" : "--:--")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(cinnabar)
            Spacer()
            recButton("scissors")
            recButton(model.paused ? "play.fill" : "pause.fill")
            recButton("stop.fill", destructive: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(cinnabar.opacity(model.recording ? 0.08 : 0.0))
        .opacity(model.recording || model.paused ? 1 : 0.45)
    }

    private func recButton(_ symbol: String, destructive: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(destructive ? Color(red: 0.94, green: 0.65, blue: 0.61) : paperOnInk)
            .frame(width: 22, height: 22)
            .background(destructive ? Color(red: 0.7, green: 0.23, blue: 0.18).opacity(0.4)
                                    : paperOnInk.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}
