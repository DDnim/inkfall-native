import AppKit
import SwiftUI
import InkfallCore

/// 设置窗。减法之后只剩三页：模型 / 快捷键 / 通用。
@MainActor
final class HubWindowController {

    private var window: NSWindow?
    private let model: HubModel

    init(store: SettingsStore, permissions: PermissionCoordinator, models: ModelCatalog) {
        model = HubModel(store: store, permissions: permissions, models: models)
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "落音 Inkfall"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 480)
        let host = NSHostingView(rootView: HubView(model: model))
        // ⚠️ NSHostingView 默认把 SwiftUI 内容的尺寸诉求传播给窗口，
        // 会把窗口撑到内容的理想高度（实测 760 → 866）。窗口尺寸由我们定，
        // 不由内容定。
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 520, height: 680))
        w.center()
        window = w
    }
}

@MainActor
@Observable
final class HubModel {
    enum Page: String, CaseIterable, Identifiable {
        case operators, shortcuts, general

        var id: String { rawValue }
        var title: String {
            switch self {
            case .operators: return "模型"
            case .shortcuts: return "快捷键"
            case .general: return "通用"
            }
        }
    }

    var selection: Page = .operators
    let store: SettingsStore
    let permissions: PermissionCoordinator
    let models: ModelCatalog
    /// 设置页要显示「配没配过 key」，所以它读的是同一个进程内缓存 ——
    /// 不是每次重绘都去 fork 一个 `security`。
    let keys = APIKeyStore.shared

    init(store: SettingsStore, permissions: PermissionCoordinator, models: ModelCatalog) {
        self.store = store
        self.permissions = permissions
        self.models = models
    }

    var settings: AppSettings {
        get { store.settings }
        set { store.settings = newValue; store.save() }
    }
}

struct HubView: View {
    @Bindable var model: HubModel

    var body: some View {
        settings
            .background(Ink.paper1)
            .overlay(alignment: .bottom) { statusBar }
    }

    // MARK: - 设置

    private var settings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(HubModel.Page.allCases) { page in
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
                    sourceCard("落音云", "推荐 · 无需 key",
                               on: model.settings.transcriptionMode == .groqProxy) {
                        model.settings.transcriptionMode = .groqProxy
                    }
                    sourceCard("自定义", "BYOK", on: byokProvider != nil) {
                        // 已经配了 key 的供应商优先；一个都没配就默认 Groq（又快又便宜）。
                        let preferred = CloudProvider.allCases.first { model.keys.isConfigured($0) } ?? .groq
                        model.settings.transcriptionMode = preferred.transcriptionMode
                    }
                    sourceCard("本地", "离线 · CoreML",
                               on: model.settings.transcriptionMode == .local) {
                        model.settings.transcriptionMode = .local
                    }
                }
                transcriptionSourceRows
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
                providerRow
                apiKeyRow(model.settings.postProcessingProvider)
                if model.settings.postProcessingPreset == .custom {
                    customPromptRow
                }
                toggleRow("离线降级", "只在网络 / 5xx 时降级；鉴权与配额问题会浮出来",
                          isOn: Binding(get: { model.settings.autoLocalFallbackEnabled },
                                        set: { model.settings.autoLocalFallbackEnabled = $0 }))
            }
            caption("「基础整理」是纯本地规则（去口头禅、补标点），不联网也不要 key；"
                    + "其余八个预设要调模型。录音短于 3 秒或不足 10 字时自动退回本地整理，"
                    + "没配 key 时也一样 —— 文字永远不会因为加工失败而丢。")
        }
    }

    /// 自定义（BYOK）时选的是哪家；落音云 / 本地时为 nil。
    private var byokProvider: CloudProvider? {
        model.settings.transcriptionMode.cloudProviderForSelfTest
    }

    /// 三张卡下面跟着的那几行：落音云要地址，BYOK 要供应商 + 模型 + key，本地什么都不要。
    @ViewBuilder private var transcriptionSourceRows: some View {
        switch model.settings.transcriptionMode {
        case .groqProxy:
            textRow("落音云地址", placeholder: "https://…（环境变量 INKFALL_GROQ_PROXY_URL 优先）",
                    text: Binding(get: { model.settings.groqProxyUrl },
                                  set: { model.settings.groqProxyUrl = $0 }))
            textRow("代理令牌（可选）", placeholder: "自托管部署用的 X-Proxy-Token",
                    text: Binding(get: { model.settings.groqProxyToken },
                                  set: { model.settings.groqProxyToken = $0 }))
            caption("鉴权顺序：登录会话（钥匙串里的 inkfall_session_token）→ 代理令牌 → 匿名。"
                    + "服务端持 Groq key，音频只经过落音云。")
        case .openai, .groq, .gemini:
            let provider = byokProvider ?? .groq
            HStack(spacing: 9) {
                Text("供应商").font(.system(size: 12)).foregroundStyle(Ink.ink1)
                Spacer(minLength: 6)
                Picker("", selection: Binding(
                    get: { provider },
                    set: { model.settings.transcriptionMode = $0.transcriptionMode })) {
                    ForEach(CloudProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
            transcriptionModelRow(provider)
            apiKeyRow(provider)
            caption(provider == .gemini
                    ? "Gemini 没有转写端点，音频作为 inline_data 走 generateContent；不报检测语言。"
                    : "音频直接发给 \(provider.label)；专有名词表作为 prompt 一起送。"
                      + "网络 / 5xx 时降级到本地模型，鉴权与配额问题会浮出来。")
        case .local:
            EmptyView()
        }
    }

    private func transcriptionModelRow(_ provider: CloudProvider) -> some View {
        let options: [String]
        let selection: Binding<String>
        switch provider {
        case .openai:
            options = ProviderModels.openAITranscription
            selection = Binding(get: { model.settings.selectedOpenAiModel },
                                set: { model.settings.selectedOpenAiModel = $0 })
        case .groq:
            options = ProviderModels.groqTranscription
            selection = Binding(get: { model.settings.selectedGroqModel },
                                set: { model.settings.selectedGroqModel = $0 })
        case .gemini:
            options = ProviderModels.gemini
            selection = Binding(get: { model.settings.selectedGeminiModel },
                                set: { model.settings.selectedGeminiModel = $0 })
        }
        return HStack(spacing: 9) {
            Text("转写模型").font(.system(size: 12)).foregroundStyle(Ink.ink1)
            Spacer(minLength: 6)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 220)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }

    private func textRow(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(Ink.ink1)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Ink.paper4, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hair))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
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
            caption("按住说话：按下起录，松开转写并插回原窗口。"
                    + "切换录音：按一下开始长录音，再按一下转写并插回。"
                    + "改绑定要编辑 shortcuts.json（录制界面见 #44）。")
        }
    }

    private var shortcutRows: [(String, String)] {
        [("按住说话", model.store.shortcuts.overlayHold.displayLabel),
         ("切换录音", model.store.shortcuts.toggleRecording.displayLabel)]
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

    private func sourceCard(_ title: String, _ subtitle: String, on: Bool,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.ink1)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(Ink.ink4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(on ? Ink.paper4 : Ink.paper2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(on ? Ink.cinnabar.opacity(0.6) : Ink.hair, lineWidth: on ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
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
