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

    init(store: SettingsStore, permissions: PermissionCoordinator,
         models: ModelCatalog, notes: NoteStore,
         onOpenNote: @escaping (HistoryEntry) -> Void) {
        model = HubModel(store: store, permissions: permissions, models: models, notes: notes)
        model.onOpenNote = onOpenNote
    }

    func show(page: HubModel.Page? = nil) {
        ensureWindow()
        if let page { model.selection = page }
        // 权重可能被用户在访达里删掉了 —— 每次打开都按磁盘现状重来。
        model.models.refresh()
        // 设置页会显示三个供应商各自配没配过 key，所以这里把它们都预热一遍
        // （后台线程；平时的听写路径只预热真正在用的那个）。
        model.keys.preload(Set(CloudProvider.allCases))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var debugFrame: NSRect? { window?.frame }
    /// 取证用：SwiftUI 真的画出东西了，这里就有对应的宿主视图与文本视图；
    /// 画不出来就是一层空壳。截图受 TCC 限制、AX 自读窗口树在本机时灵时不灵，
    /// 所以这是「这一页到底渲染出来没有」最可靠的一条通道。
    var debugContentView: NSView? { window?.contentView }

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
    let models: ModelCatalog
    let notes: NoteStore
    /// 设置页要显示「配没配过 key」，所以它读的是同一个进程内缓存 ——
    /// 不是每次重绘都去 fork 一个 `security`。
    let keys = APIKeyStore.shared
    /// 点一条笔记要干什么。宿主（AppDelegate）注入 —— 合并窗不该自己知道
    /// 落笔面板的存在。
    var onOpenNote: ((HistoryEntry) -> Void)?

    init(store: SettingsStore, permissions: PermissionCoordinator,
         models: ModelCatalog, notes: NoteStore) {
        self.store = store
        self.permissions = permissions
        self.models = models
        self.notes = notes
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

    private var emptyHome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有笔记")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.ink2)
            Text("按 ⌥Space 开始一段落笔录音 —— 说到停顿会自动切段，停下来之后正文可以直接编辑。每次开始录音都会新建一篇，最多保留 100 条。")
                .font(.system(size: 11.5)).foregroundStyle(Ink.ink4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// 搜索按标题与正文一起匹配 —— 用户记得的往往是内容，不是自动生成的时间标题。
    private var notes: [HistoryEntry] {
        let all = model.notes.notes
        let query = model.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.finalText.localizedCaseInsensitiveContains(query)
        }
    }

    private func noteRow(_ note: HistoryEntry) -> some View {
        NoteRow(note: note,
                open: { model.onOpenNote?(note) },
                delete: { deleteNote(note) })
    }

    private func deleteNote(_ note: HistoryEntry) {
        let alert = NSAlert()
        alert.messageText = "删除「\(note.title)」？"
        alert.informativeText = "正文与其中的截图都会被删掉，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.notes.remove(id: note.id)
        NoteAttachments.removeAll(noteID: note.id)
    }

    private var footerHints: some View {
        HStack(spacing: 8) {
            ForEach([("点击", "打开编辑"), ("⌥Space", "开始录音"),
                     ("⌥;", "截图"), ("esc", "关闭")], id: \.0) { pair in
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
                    case .screenshot: screenshotPage
                    case .voiceCommands: voiceCommandsPage
                    case .integration: integrationPage
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

    private var screenshotPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("截图") {
                toggleRow("启用截图", "⌥; 框选、⌥' 整屏，截完直接插进当前笔记。"
                          + "关掉之后这两个组合键会原样透传给别的 App",
                          isOn: Binding(get: { model.settings.screenshotFeatureEnabled },
                                        set: { model.settings.screenshotFeatureEnabled = $0 }))
                caption("图片存在 ~/Library/Application Support/app.inkfall.native/attachments/，"
                        + "删除笔记时会连同它的图片一起删掉。")
            }
            group("权限") {
                permissionRow(.screenRecording)
            }
        }
    }

    private var operatorsPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("模型来源") {
                HStack(spacing: 6) {
                    sourceCard("落音云", "推荐 · 无需 key", on: model.settings.transcriptionMode == .groqProxy)
                    sourceCard("自定义", "BYOK", on: [.openai, .groq, .gemini].contains(model.settings.transcriptionMode))
                    sourceCard("本地", "离线 · CoreML", on: model.settings.transcriptionMode == .local)
                }
            }
            group("本地模型") {
                ForEach(model.models.entries) { entry in
                    modelRow(entry)
                }
            }
            group("区分人物") {
                toggleRow("区分人物", "把「谁在说」贴进转写结果。适合会议与访谈；"
                          + "一个人说话时不会加标签。开着会让每段多花一点时间",
                          isOn: Binding(get: { model.models.diarizationEnabled },
                                        set: { model.models.setDiarizationEnabled($0) }))
                diarizationRow
            }
            caption("权重按需下载到 App 容器（\(LocalTranscriber.modelRoot.lastPathComponent)/），"
                    + "不进安装包。推理运行时是编译进程序的，不需要另外装任何东西。"
                    + "空闲 5 分钟会把模型从内存卸掉。")
            group("加工") {
                toggleRow("AI 加工", "转写后再过一遍大模型。关掉就是原样输出",
                          isOn: Binding(get: { model.settings.postProcessingEnabled },
                                        set: { model.settings.postProcessingEnabled = $0 }))
                presetRow
                engineRow
                if model.settings.postProcessingEngine == .cloud {
                    providerRow
                    apiKeyRow(model.settings.postProcessingProvider)
                } else {
                    cliAgentRows
                }
                if model.settings.postProcessingPreset == .custom {
                    customPromptRow
                }
                toggleRow("近期上下文", "最近 6 条作参考，保持术语一致",
                          isOn: Binding(get: { model.settings.recentContextEnabled },
                                        set: { model.settings.recentContextEnabled = $0 }))
                toggleRow("离线降级", "只在网络 / 5xx 时降级；鉴权与配额问题会浮出来",
                          isOn: Binding(get: { model.settings.autoLocalFallbackEnabled },
                                        set: { model.settings.autoLocalFallbackEnabled = $0 }))
            }
            caption("「基础整理」是纯本地规则（去口头禅、补标点），不联网也不要 key；"
                    + "其余八个预设要调模型。录音短于 3 秒或不足 10 字时自动退回本地整理，"
                    + "没配 key 时也一样 —— 文字永远不会因为加工失败而丢。"
                    + "右⌥ + F1…F9 直接切预设。")

            group("落笔的加工") {
                toggleRow("落笔单独加工", "笔记面板用自己的开关与预设，和听写互不影响",
                          isOn: Binding(get: { model.settings.noteProcessingEnabled },
                                        set: { model.settings.noteProcessingEnabled = $0 }))
                pickerRow("落笔预设",
                          Binding(get: { model.settings.noteProcessingPreset },
                                  set: { model.settings.noteProcessingPreset = $0 }))
            }
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("录音") {
                toggleRow("麦克风增益提升", "macOS 自动增益会把输入音量拖到 30%，录音太轻转不出来",
                          isOn: Binding(get: { model.settings.micGainBoostEnabled },
                                        set: { model.settings.micGainBoostEnabled = $0 }))
            }
            group("粘贴") {
                toggleRow("自动粘贴", "听写完直接粘回起录时的那个窗口。"
                          + "关掉之后只复制到剪贴板，不合成任何按键",
                          isOn: Binding(get: { model.settings.autoPasteEnabled },
                                        set: { model.settings.autoPasteEnabled = $0 }))
                toggleRow("粘贴后补换行", "每段末尾加一个换行，连续听写会落在不同行上。"
                          + "默认关：行内听写不该凭空多一个换行",
                          isOn: Binding(get: { model.settings.pasteAppendNewline },
                                        set: { model.settings.pasteAppendNewline = $0 }))
                // 粘贴走的是合成 ⌘V，没有这个权限系统会把按键**静默丢掉** ——
                // 表现为「刘海说粘好了，窗口里什么都没有」。所以这一行贴在这里，
                // 不只是在下面的权限组里。
                if !model.permissions.isGranted(.accessibility) {
                    permissionRow(.accessibility)
                    caption("没有辅助功能授权，粘贴会自动降级为「复制到剪贴板」。")
                }
            }
            group("落笔") {
                toggleRow("自动断句", "停顿约 1.3 秒自动切一段",
                          isOn: Binding(get: { model.settings.noteAutoSegment },
                                        set: { model.settings.noteAutoSegment = $0 }))
                // 和上面「粘贴」组里那个总开关区分开：这一个管的是落笔的**每一段**。
                toggleRow("逐段自动粘贴", "每段转写完立刻插入目标窗口",
                          isOn: Binding(get: { model.settings.noteAutoPaste },
                                        set: { model.settings.noteAutoPaste = $0 }))
                toggleRow("自动会议笔记（Beta）",
                          "边录边在正文旁边整理出一份会议笔记（议题/决定/待办），"
                          + "另存为一条笔记，不动原转写。说满 100 字后开始，"
                          + "每次整理都要一次模型往返，会额外花钱",
                          isOn: Binding(get: { model.settings.meetingNotesEnabled },
                                        set: { model.settings.meetingNotesEnabled = $0 }))
                toggleRow("启动时恢复上次会话", "未粘贴的内容不会因为重启而丢",
                          isOn: Binding(get: { model.settings.noteRestoreOnLaunch },
                                        set: { model.settings.noteRestoreOnLaunch = $0 }))
            }
            group("权限") {
                ForEach(Permission.allCases, id: \.self) { permissionRow($0) }
            }
        }
    }

    private func permissionRow(_ p: Permission) -> some View {
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
        [("按住说话", "右 ⌥"), ("落笔", "⌥ Space"), ("贾维斯待命", "⌥ ,"),
         ("快速粘贴", "⌥ ["), ("切段", "⌥ ."), ("发送前编辑", "⌥ /"),
         ("取消录音", "⌥ Esc"), ("撤销待执行命令", "esc（仅倒计时期间）"),
         ("立即执行", "↩（仅倒计时期间）")]
    }

    // MARK: - 子页：语音命令 / 贾维斯

    private var voiceCommandsPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("总开关") {
                toggleRow("语音命令", "口述里出现关键词时，不粘贴，改为在终端里执行一条命令。"
                          + "默认关：随口一句以关键词开头的听写就会启动终端，而命令是任意 shell",
                          isOn: Binding(get: { model.settings.voiceCommandsEnabled },
                                        set: { model.settings.voiceCommandsEnabled = $0 }))
                toggleRow("按住提问（双击右⌥ 并按住）", "快速点一下右⌥、立刻再按住，"
                          + "说完松开 —— 问题连同选中的文字交给 Claude Code，"
                          + "答案显示出来，不粘贴。关掉之后这个手势退化成普通听写",
                          isOn: Binding(get: { model.settings.askModeEnabled },
                                        set: { model.settings.askModeEnabled = $0 }))
                toggleRow("贾维斯待命（⌥,）", "一直听着，只扫关键词，不留任何文字。"
                          + "落笔开着时可以叠加 —— 那时每段既留下又扫描",
                          isOn: Binding(get: { model.settings.jarvisModeEnabled },
                                        set: { model.settings.jarvisModeEnabled = $0 }))
            }
            caption("命中之后有 3 秒倒计时：esc 撤销，↩ 立即执行。"
                    + "这两个键**只在**倒计时期间被接管，其余时间原样透传。")

            group("命令") {
                ForEach(Array(model.settings.voiceCommands.enumerated()), id: \.offset) { pair in
                    commandCard(index: pair.offset)
                }
                HStack {
                    Button("＋ 新增命令") {
                        model.settings.voiceCommands.append(
                            VoiceCommand(keyword: "", commandTemplate: "", terminal: .terminal))
                    }
                    .font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
            }
            caption("占位符：{text} 是整句话减去关键词，{selection} 是当前选中的文字，"
                    + "{clipboard} 是剪贴板。终端命令里要把它们包在双引号里 ——"
                    + "替换值按双引号 shell 上下文转义，换行会压成空格；"
                    + "Claude Code 那一路模板就是提问本身，引号和分行原样保留。")

            group("Claude Code 助手") {
                caption2("选「Claude Code」的命令不开终端窗口：后台 tmux 里跑 claude -p，"
                         + "同一个关键词的后续每一句都 --resume 接回同一场会话 ——"
                         + "所以它记得住上下文。回答落在刘海上，全文进剪贴板。")
                copyRow("看对话", "tmux attach -t \(ClaudeCode.tmuxSession)")
                HStack(spacing: 8) {
                    Text("环境").font(.system(size: 11)).foregroundStyle(Ink.ink2)
                        .frame(width: 52, alignment: .leading)
                    Text(ClaudeCodeAgent.readiness)
                        .font(.system(size: 10))
                        .foregroundStyle(ClaudeCodeAgent.readiness == "就绪" ? Ink.teal : Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
                caption2("「跳过权限确认」默认关：语音是会误触的输入方式，"
                         + "而它等于把改文件、跑命令的确认全免掉。关着时仍然能读能查能答。")
            }
        }
    }

    /// 一条命令。380pt 宽的子页放不下一行摆完，所以竖着排。
    private func commandCard(index: Int) -> some View {
        let command = Binding(
            get: { model.settings.voiceCommands[safe: index] ?? VoiceCommand() },
            set: {
                guard model.settings.voiceCommands.indices.contains(index) else { return }
                model.settings.voiceCommands[index] = $0
            })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("关键词", text: command.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
                Toggle("", isOn: command.enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Button {
                    model.settings.voiceCommands.remove(at: index)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(Ink.ink3)
            }
            TextField("命令模板，例如 claude \"{text}。{selection}\"",
                      text: command.commandTemplate, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1...3)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
            HStack(spacing: 6) {
                Picker("", selection: command.runner) {
                    ForEach(VoiceCommandRunner.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 108)
                Picker("", selection: command.keywordPosition) {
                    ForEach(KeywordPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().controlSize(.small)
            }
            if command.runner.wrappedValue == .claudeCode {
                claudeRow(command)
            } else {
                terminalRow(command)
            }
            miniToggle("连续对话", command.continuousConversation)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    /// 终端命令那一路的三个开关。
    /// 「新标签页」必须激活终端，所以它和「保持焦点」互斥；
    /// Ghostty 没有脚本接口，对它整项置灰。
    private func terminalRow(_ command: Binding<VoiceCommand>) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: command.terminal) {
                ForEach(TerminalApp.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 92)
            miniToggle("保持焦点", command.keepFocus)
                .disabled(command.openInNewTab.wrappedValue)
            miniToggle("新标签页", command.openInNewTab)
                .disabled(!command.terminal.wrappedValue.supportsNewTab)
        }
    }

    /// Claude Code 那一路：跑在哪个目录、要不要免掉权限确认。
    private func claudeRow(_ command: Binding<VoiceCommand>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("工作目录（空 = 用户主目录）", text: command.workingDirectory)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
            miniToggle("允许联网查资料（WebSearch / WebFetch，只读）", command.allowWebTools)
            miniToggle("跳过权限确认（能改文件、能跑命令）", command.skipPermissions)
                .foregroundStyle(command.skipPermissions.wrappedValue ? Ink.amber : Ink.ink2)
        }
    }

    private func miniToggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 10)).foregroundStyle(Ink.ink2)
        }
        .toggleStyle(.checkbox).controlSize(.mini)
    }

    // MARK: - 子页：集成

    private var integrationPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            group("本地 API") {
                toggleRow("允许本地读写笔记", "把笔记的增删改查暴露给任何持 token 的本机进程"
                          + "（MCP 桥、curl、脚本）。只监听 127.0.0.1，默认关",
                          isOn: Binding(get: { model.settings.integrationApiEnabled },
                                        set: { model.settings.integrationApiEnabled = $0 }))
                copyRow("地址", "http://127.0.0.1:\(IntegrationStore.port)/api/notes")
                copyRow("令牌", IntegrationStore.token(), masked: true)
                HStack {
                    Button("重新生成令牌") { _ = IntegrationStore.regenerate() }
                        .font(.system(size: 11))
                    Spacer()
                    Text("0600 · 只有你读得到")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
            }
            caption("五条路由：GET /api/notes 列表、GET /api/notes/<id> 详情、"
                    + "POST 新建、PATCH 改标题或正文、DELETE 删除。"
                    + "开关关着是 403，token 不对是 401。")

            group("MCP 桥") {
                copyRow("注册命令", IntegrationStore.registerCommand)
                caption2("把上面这行贴进终端，编码助手就能读写你的笔记。"
                         + "脚本每次启动都会重写一遍 —— App 升级后自动最新，路径不变。")
            }
            group("调试通道") {
                caption2("/health 报权限与快捷键；/debug/overlay/state 报刘海真实几何；"
                         + "/debug/note/state 报当前会话；/debug/jarvis/{state,match,take,toggle} "
                         + "走真实分发路径。这几条不需要 token（只监听回环），"
                         + "但都只读或无害 —— 写操作一律走 /api/*。")
            }
        }
    }

    private func copyRow(_ label: String, _ value: String, masked: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Ink.ink2).frame(width: 52,
                                                                                alignment: .leading)
            Text(masked ? String(value.prefix(8)) + "…" + String(value.suffix(4)) : value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.ink1)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Ink.ink3)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    private func caption2(_ text: String) -> some View {
        caption(text).padding(.horizontal, 11).padding(.bottom, 8)
    }

    private var notWiredYet: some View {
        caption("这一页还没接上（里程碑 2–3）。")
    }

    // MARK: - 加工的几行

    private var presetRow: some View {
        pickerRow("预设", Binding(get: { model.settings.postProcessingPreset },
                                 set: { model.settings.postProcessingPreset = $0 }))
    }

    private func pickerRow(_ label: String,
                           _ selection: Binding<PostProcessingPreset>) -> some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.ink1)
            Spacer(minLength: 6)
            Picker("", selection: selection) {
                ForEach(PostProcessingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 150)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    /// 谁来跑这次加工。以后加 gemini-cli / codex-cli 时这个下拉框自己会长出来。
    private var engineRow: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("引擎").font(.system(size: 12)).foregroundStyle(Ink.ink1)
                Text("云端 API 要 key；Claude Code 用本机已经装好的 claude")
                    .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
            }
            Spacer(minLength: 6)
            Picker("", selection: Binding(get: { model.settings.postProcessingEngine },
                                          set: { model.settings.postProcessingEngine = $0 })) {
                ForEach(PostProcessingEngine.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 150)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    /// 加工供应商跟随转写供应商（本地转写例外，可以独立选）。
    @ViewBuilder private var providerRow: some View {
        if model.settings.transcriptionMode == .local {
            HStack(spacing: 9) {
                Text("供应商").font(.system(size: 12)).foregroundStyle(Ink.ink1)
                Spacer(minLength: 6)
                Picker("", selection: Binding(
                    get: { model.settings.postProcessingProvider },
                    set: { model.settings.postProcessingProvider = $0 })) {
                    ForEach(CloudProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
        } else {
            HStack {
                Text("供应商跟随转写：\(model.settings.postProcessingProvider.label)")
                    .font(.system(size: 10.5)).foregroundStyle(Ink.ink4)
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
        }
    }

    /// CLI 助手那条路：装没装 + 思考力度。**不要 key** —— 用的是那个工具
    /// 自己的登录态。
    @ViewBuilder private var cliAgentRows: some View {
        if let agent = model.settings.postProcessingEngine.cliAgent {
            let installed = CLIAgentLocator.path(for: agent) != nil
            HStack(spacing: 9) {
                Image(systemName: installed ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(installed ? Ink.teal : Ink.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed ? "已找到 \(agent.executable)"
                                   : "没找到 \(agent.executable) —— 先装 \(agent.label)")
                        .font(.system(size: 11)).foregroundStyle(Ink.ink2)
                    Text("用它自己的登录态，不需要另外配 key")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().overlay(Ink.hair) }

            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("思考力度").font(.system(size: 12)).foregroundStyle(Ink.ink1)
                    Text("加工没什么可想的。往上调只会更慢更贵")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                }
                Spacer(minLength: 6)
                Picker("", selection: Binding(get: { model.settings.cliAgentEffort },
                                              set: { model.settings.cliAgentEffort = $0 })) {
                    ForEach(agent.effortLevels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
        }
    }

    // MARK: - API key

    private func apiKeyRow(_ provider: CloudProvider) -> some View {
        keyRow(title: "\(provider.label) API key",
               hint: provider == .groq ? "以 gsk_ 开头；整段粘贴也行，会自动抠出来"
                                       : "粘贴时带不带 Bearer 都行",
               masked: model.keys.maskedKey(provider),
               fromEnvironment: model.keys.isFromEnvironment(provider),
               environmentName: APIKeyNormalization.environmentVariableName(provider),
               save: { try model.keys.save($0, for: provider) },
               clear: { model.keys.clear(provider) })
    }

    private func keyRow(title: String, hint: String, masked: String?,
                        fromEnvironment: Bool, environmentName: String,
                        save: @escaping (String) throws -> Void,
                        clear: @escaping () -> Void) -> some View {
        KeyRow(title: title, hint: hint, masked: masked, fromEnvironment: fromEnvironment,
               environmentName: environmentName, save: save, clear: clear)
    }

    private var customPromptRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("自定义 prompt").font(.system(size: 12)).foregroundStyle(Ink.ink1)
            TextField("例如：Translate to English, keeping the tone.",
                      text: Binding(get: { model.settings.customPostProcessingPrompt },
                                    set: { model.settings.customPostProcessingPrompt = $0 }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(2...5)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
            // 自定义预设**刻意不带**「保持原语言」那条规则 —— 用户完全可能
            // 就是要翻译。护栏（别回答转写里的问题）仍然带着。
            Text("自定义 prompt 不会被强制「保持原语言」，所以可以用来翻译。")
                .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
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

    /// 分离模型独立于转写档位 —— 单列一行，免得看成「和 Whisper 二选一」。
    private var diarizationRow: some View {
        let state = model.models.diarization
        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: "person.2")
                .foregroundStyle(state.downloaded ? Ink.teal : Ink.ink4)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Pyannote 说话人分离").font(.system(size: 12)).foregroundStyle(Ink.ink1)
                if let progress = state.progress {
                    Text("下载中 \(Int(progress * 100))%")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                } else {
                    Text((state.downloaded ? "已下载 · " : "未下载 · ") + state.sizeText
                         + " · 与转写模型并行跑")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                }
            }
            Spacer(minLength: 6)
            if state.progress != nil {
                ProgressView().controlSize(.small)
            } else if state.downloaded {
                Button("删除") { model.models.deleteDiarization() }.font(.system(size: 11))
            } else {
                Button("下载") { model.models.downloadDiarization() }
                    .font(.system(size: 11))
                    .disabled(model.models.busy != nil)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    /// 一行本地模型：勾选态、体积/下载进度、下载或删除。
    private func modelRow(_ entry: ModelCatalog.Entry) -> some View {
        let isSelected = entry.id == model.models.selectedID
        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Ink.cinnabar : Ink.ink4)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.model.name).font(.system(size: 12)).foregroundStyle(Ink.ink1)
                if let progress = entry.progress {
                    Text("下载中 \(Int(progress * 100))%")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                } else {
                    Text(entry.downloaded ? "已下载 · \(entry.sizeText)"
                                          : "未下载 · \(entry.sizeText)")
                        .font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                }
            }
            Spacer(minLength: 6)
            if entry.progress != nil {
                ProgressView().controlSize(.small)
            } else if entry.downloaded {
                Button("删除") { model.models.delete(entry.id) }
                    .font(.system(size: 11))
            } else {
                Button("下载") { model.models.download(entry.id) }
                    .font(.system(size: 11))
                    .disabled(model.models.busy != nil)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
        .contentShape(Rectangle())
        // 整行可点 —— 只有那个小圆点能点是设置页里最烦人的交互之一。
        .onTapGesture { model.models.select(entry.id) }
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

/// 一把 API key 的那一行：状态、输入、保存、删除。
///
/// 单独抽出来是为了 `@State` —— 输入框和错误提示是这一行自己的事，
/// 不该塞进 `HubModel`（那样每敲一个字都会把整份设置写一次盘）。
///
/// 永远只显示遮罩后的形式：设置页会被截图、会被投屏。
private struct KeyRow: View {
    let title: String
    let hint: String
    let masked: String?
    let fromEnvironment: Bool
    let environmentName: String
    let save: (String) throws -> Void
    let clear: () -> Void

    @State private var input = ""
    @State private var error: String?
    @State private var justSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(Ink.ink1)
                Spacer(minLength: 4)
                if let masked {
                    Text(masked)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.teal)
                    if fromEnvironment {
                        // 环境变量给的 key 删不掉（它不在钥匙串里），
                        // 说破比给一个点了没反应的按钮好。
                        Text("来自 \(environmentName)")
                            .font(.system(size: 9)).foregroundStyle(Ink.ink4)
                    } else {
                        Button("删除") { clear(); justSaved = false }
                            .font(.system(size: 10.5))
                    }
                } else {
                    Text("未配置").font(.system(size: 10)).foregroundStyle(Ink.amber)
                }
            }
            if !fromEnvironment {
                HStack(spacing: 6) {
                    SecureField("粘贴 key", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
                        .onSubmit(commit)
                    Button("保存", action: commit)
                        .font(.system(size: 11))
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error {
                Text(error).font(.system(size: 9.5)).foregroundStyle(Ink.amber)
            } else if justSaved {
                Text("已存进钥匙串").font(.system(size: 9.5)).foregroundStyle(Ink.teal)
            } else {
                Text(hint).font(.system(size: 9.5)).foregroundStyle(Ink.ink4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    private func commit() {
        do {
            try save(input)
            // 明文一秒都不多留在内存里。
            input = ""
            error = nil
            justSaved = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            justSaved = false
        }
    }
}

/// 笔记列表的一行。
///
/// 单独抽出来是为了 `@State` 的悬停态 —— 删除按钮只在鼠标移上来时出现，
/// 否则一列垃圾桶图标会让「打开」这个主要动作显得次要。
private struct NoteRow: View {
    let note: HistoryEntry
    let open: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.ink1)
                // 正文是 markdown，列表这一行只要个摘要 —— 把换行压成空格，
                // 否则第一行是个标题井号就什么都看不出来。
                Text(note.displayText.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.ink3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.ink3)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("删除这篇")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Ink.paper3 : .clear)
        .contentShape(Rectangle())          // 空白处也要能点，不是只有文字
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Divider().overlay(Ink.hair) }
    }
}
