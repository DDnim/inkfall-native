import AppKit
import SwiftUI
import InkfallCore

/// 合并窗：**笔记是主页，设置是子页**。
///
/// 打开这扇窗最常见的目的是粘贴一条笔记，不是改设置。所以笔记列表就是主页，
/// 设置从右侧推入；齿轮是唯一可见的设置入口（托盘 ⌘, 也能到）。
@MainActor
final class HubWindowController {

    private var window: NSWindow?
    private let model: HubModel

    init(store: SettingsStore, permissions: PermissionCoordinator) {
        model = HubModel(store: store, permissions: permissions)
    }

    func show(page: HubModel.Page? = nil) {
        ensureWindow()
        if let page { model.selection = page }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var debugFrame: NSRect? { window?.frame }

    private func ensureWindow() {
        guard window == nil else { return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "落音 Inkfall"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 820, height: 560)
        let host = NSHostingView(rootView: HubView(model: model))
        // ⚠️ NSHostingView 默认把 SwiftUI 内容的尺寸诉求传播给窗口，
        // 会把窗口撑到内容的理想高度（实测 760 → 866）。窗口尺寸由我们定，
        // 不由内容定。
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 980, height: 760))
        w.center()
        window = w
    }
}

@MainActor
@Observable
final class HubModel {
    /// 设置子页。注意**没有** `history`（笔记列表就是主页本身）
    /// 也**没有** `account`（账号面板钉在侧栏底部）。
    enum Page: String, CaseIterable, Identifiable {
        case home            // 主页，不是子页
        case operators, shortcuts, voiceCommands, screenshot, general, integration

        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "笔记"
            case .operators: return "模型"
            case .shortcuts: return "快捷键"
            case .voiceCommands: return "语音命令"
            case .screenshot: return "截图"
            case .general: return "通用"
            case .integration: return "集成"
            }
        }
        static var subPages: [Page] {
            allCases.filter { $0 != .home }
        }
    }

    var selection: Page = .home
    var query = ""
    let store: SettingsStore
    let permissions: PermissionCoordinator

    init(store: SettingsStore, permissions: PermissionCoordinator) {
        self.store = store
        self.permissions = permissions
    }

    var settings: AppSettings {
        get { store.settings }
        set { store.settings = newValue; store.save() }
    }
}

struct HubView: View {
    @Bindable var model: HubModel

    var body: some View {
        HStack(spacing: 0) {
            home
            if model.selection != .home {
                Divider().overlay(Ink.hair)
                subPage.frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Ink.paper1)
        .animation(.spring(duration: 0.3), value: model.selection)
        .overlay(alignment: .bottom) { statusBar }
    }

    // MARK: - 主页：笔记列表

    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                TextField("搜索笔记…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ink.hair))
                Text("\(notes.count) 篇")
                    .font(.system(size: 10)).foregroundStyle(Ink.ink4)
                // 主页工具栏没有别的设置入口，齿轮就是那个可发现的入口。
                Button {
                    model.selection = .operators
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.ink2)
                .frame(width: 24, height: 24)
                .background(Ink.paper3, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ink.hair))
            }
            .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 10)

            Divider().overlay(Ink.hair)

            if notes.isEmpty {
                emptyHome
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notes) { note in noteRow(note) }
                    }
                }
            }

            Spacer(minLength: 0)
            footerHints
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 骨架阶段还没有真实笔记 —— 说清楚为什么空，而不是给一个沉默的白板。
    private var emptyHome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有笔记")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.ink2)
            Text("录音与转写还没接上（里程碑 1）。接上之后，每一次听写与每一段落笔都会落在这里，最多保留 100 条。")
                .font(.system(size: 11.5)).foregroundStyle(Ink.ink4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var notes: [HistoryEntry] { [] }   // 里程碑 1 接上历史存储

    private func noteRow(_ note: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(note.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.ink1)
                Spacer()
            }
            Text(note.displayText).font(.system(size: 11))
                .foregroundStyle(Ink.ink3).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(Ink.hair) }
    }

    private var footerHints: some View {
        HStack(spacing: 8) {
            ForEach([("↑↓", "选择"), ("↵", "粘贴"), ("⌘↵", "编辑"), ("esc", "关闭")], id: \.0) { pair in
                HStack(spacing: 4) {
                    Text(pair.0)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Ink.paper3, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.hair))
                    Text(pair.1).font(.system(size: 9.5)).foregroundStyle(Ink.ink3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    // MARK: - 子页：设置

    private var subPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    model.selection = .home
                } label: {
                    Text("‹ 返回").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Ink.cinnabar)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(HubModel.Page.subPages) { page in
                            Button { model.selection = page } label: {
                                Text(page.title).font(.system(size: 9.5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(model.selection == page ? .white : Ink.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(model.selection == page ? Ink.cinnabar : Ink.paper4,
                                        in: Capsule())
                            .overlay(Capsule().stroke(Ink.hair))
                        }
                    }
                }
            }
            .padding(.horizontal, 13).padding(.top, 34).padding(.bottom, 9)

            Divider().overlay(Ink.hair)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.selection.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Ink.ink1)
                        .padding(.top, 12)

                    switch model.selection {
                    case .operators: operatorsPage
                    case .general: generalPage
                    case .shortcuts: shortcutsPage
                    default: notWiredYet
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.bottom, 40)
            }
        }
        .background(Ink.paper2)
    }

    private var operatorsPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("模型来源") {
                HStack(spacing: 6) {
                    sourceCard("落音云", "推荐 · 无需 key", on: model.settings.transcriptionMode == .groqProxy)
                    sourceCard("自定义", "BYOK", on: [.openai, .groq, .gemini].contains(model.settings.transcriptionMode))
                    sourceCard("本地", "离线 · MLX", on: model.settings.transcriptionMode == .local)
                }
            }
            group("加工") {
                toggleRow("AI 加工", "转写后再过一遍大模型",
                          isOn: Binding(get: { model.settings.postProcessingEnabled },
                                        set: { model.settings.postProcessingEnabled = $0 }))
                toggleRow("近期上下文", "最近 6 条作参考，保持术语一致",
                          isOn: Binding(get: { model.settings.recentContextEnabled },
                                        set: { model.settings.recentContextEnabled = $0 }))
                toggleRow("离线降级", "只在网络 / 5xx 时降级；鉴权与配额问题会浮出来",
                          isOn: Binding(get: { model.settings.autoLocalFallbackEnabled },
                                        set: { model.settings.autoLocalFallbackEnabled = $0 }))
            }
            // 加工与语音命令的供应商强制对齐转写供应商（本地例外），
            // 所以这是一行只读说明，而不是一个点了没反应的下拉框。
            caption("加工供应商跟随转写供应商：当前为 \(model.settings.postProcessingProvider.label)。本地模式例外，可独立选择。")
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("录音") {
                toggleRow("麦克风增益提升", "macOS 自动增益会把输入音量拖到 30%，录音太轻转不出来",
                          isOn: Binding(get: { model.settings.micGainBoostEnabled },
                                        set: { model.settings.micGainBoostEnabled = $0 }))
            }
            group("落笔") {
                toggleRow("自动断句", "停顿约 1.3 秒自动切一段",
                          isOn: Binding(get: { model.settings.noteAutoSegment },
                                        set: { model.settings.noteAutoSegment = $0 }))
                toggleRow("自动粘贴", "每段转写完立刻插入目标窗口",
                          isOn: Binding(get: { model.settings.noteAutoPaste },
                                        set: { model.settings.noteAutoPaste = $0 }))
                toggleRow("启动时恢复上次会话", "未粘贴的内容不会因为重启而丢",
                          isOn: Binding(get: { model.settings.noteRestoreOnLaunch },
                                        set: { model.settings.noteRestoreOnLaunch = $0 }))
            }
            group("权限") {
                ForEach(Permission.allCases, id: \.self) { p in
                    HStack(spacing: 9) {
                        Image(systemName: model.permissions.isGranted(p)
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(model.permissions.isGranted(p) ? Ink.teal : Ink.ink4)
                            .font(.system(size: 13))
                        Text(p.title).font(.system(size: 12)).foregroundStyle(Ink.ink1)
                        Spacer()
                        if !model.permissions.isGranted(p) {
                            Button("授权") { model.permissions.request(p) }
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
                }
            }
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("默认绑定") {
                ForEach(shortcutRows, id: \.0) { row in
                    HStack {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(Ink.ink1)
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.ink2)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Ink.hair))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
                }
            }
            caption("热键监听器（CGEventTap）在里程碑 1 接上，届时这一页可以录制新绑定并做冲突检测。")
        }
    }

    private var shortcutRows: [(String, String)] {
        [("按住说话", "右 ⌥"), ("落笔", "⌥ Space"), ("快速粘贴", "⌥ ["),
         ("切段", "⌥ ."), ("发送前编辑", "⌥ /"), ("取消录音", "⌥ Esc")]
    }

    private var notWiredYet: some View {
        caption("这一页还没接上（里程碑 2–3）。")
    }

    // MARK: - 小组件

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Ink.cinnabar)
                .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.paper3, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Ink.hair))
    }

    private func toggleRow(_ label: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12)).foregroundStyle(Ink.ink1)
                Text(desc).font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    private func sourceCard(_ title: String, _ subtitle: String, on: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.ink1)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(Ink.ink4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(on ? Ink.paper4 : Ink.paper2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(on ? Ink.cinnabar.opacity(0.6) : Ink.hair, lineWidth: on ? 1.5 : 1))
        .padding(.horizontal, 11).padding(.bottom, 9)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Ink.ink4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusBar: some View {
        HStack {
            Text(model.permissions.requiredSatisfied ? "权限就绪" : "缺少必需权限")
                .font(.system(size: 10))
                .foregroundStyle(model.permissions.requiredSatisfied ? Ink.ink3 : Ink.amber)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Ink.paper0)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }
}
