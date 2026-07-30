import AppKit
import SwiftUI
import InkfallCore

/// 墨锭 · 刘海岛。
///
/// 窗口是一块 520 × (136 + 安全区) 的**固定画布**，永不改尺寸；可见的胶囊在
/// 里面变形。因为窗口永久 click-through，多出来的透明区域挡不住任何东西 ——
/// 「先长大再展开」的编排因此免费。
@MainActor
final class NotchOverlayController {

    private var window: NSPanel?
    private let model = NotchModel()

    /// 只有目标屏真的变了才 setFrame —— 它是这条路径上最贵的一步。
    private var currentScreenFrame: CGRect?

    // MARK: - 悬停

    /// hover 条上的三个动作。宿主注入 —— 刘海不认识会话。
    struct HoverActions {
        var cut: () -> Void
        var togglePause: () -> Void
        var stop: () -> Void
    }

    var hoverActions: HoverActions?

    /// 窗口永久 click-through，收不到 mouseEntered/Exited，只能轮询。
    /// 120ms：跟手，又不至于让一个常驻计时器变成耗电项。
    private static let hoverPollSeconds: TimeInterval = 0.12
    private var hoverTimer: Timer?

    /// 这一刻有没有 hover 条可展开。
    ///
    /// 只有长录会话有。按住说话同样是紧凑胶囊，但那时手正按在键上，
    /// 条上三个按钮一个都用不上 —— 给它展开只会挡住计时。
    func setHoverStripAvailable(_ available: Bool) {
        guard model.stripAvailable != available else { return }
        model.stripAvailable = available
        if available {
            startHoverPolling()
        } else {
            stopHoverPolling()
        }
    }

    private func startHoverPolling() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverPollSeconds,
                                          repeats: true) { _ in
            Task { @MainActor in self.pollHover() }
        }
    }

    /// ⚠️ 这里**必须无条件**把 click-through 放回去。overlay 卡在
    /// 「接受点击」是能把整个屏幕顶端点死的，而且用户完全看不出是谁在吃他的点击。
    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        model.hover = .none
        window?.ignoresMouseEvents = true
    }

    private func pollHover() {
        guard let panel = window, model.visible else {
            stopHoverPolling()
            return
        }
        // 命中判的是**当前绘制的胶囊**，不是画布 —— 画布 520×168 里绝大部分
        // 是透明的，拿它当热区会让鼠标一飘到屏幕顶端就触发。
        let rect = OverlayGeometry.capsuleRect(canvas: panel.frame, capsule: model.capsule)
        let response = OverlayHover.response(hovering: rect.contains(NSEvent.mouseLocation),
                                             stripAvailable: model.stripAvailable)
        guard response != model.hover else { return }
        model.hover = response
        panel.ignoresMouseEvents = !OverlayHover.wantsMouseEvents(response)
    }

    /// - Parameter compact: 紧凑胶囊 —— 只排一行、矮一半。录音中用它：
    ///   胶囊亮着本身就代表在录音，再写一行「正在录音」是白占屏幕顶部。
    func show(state: OverlayState, message: String = "", title: String? = nil,
              compact: Bool = false) {
        model.compact = compact
        model.state = state
        model.message = message
        model.title = title
        ensureWindow()
        position()
        window?.orderFrontRegardless()
        model.visible = true
    }

    func hide() {
        model.compact = false
        model.visible = false
        // 收走之前先把 click-through 放回去 —— 一个 orderOut 掉的窗口
        // 仍然会因为 ignoresMouseEvents=false 而在下次显示时吃掉第一次点击。
        setHoverStripAvailable(false)
        window?.orderOut(nil)
    }

    var isVisible: Bool { model.visible }

    /// 录音电平（0…1）。呼吸带的幅度直接跟着它走。
    func setLevel(_ level: Double) {
        model.level = min(max(level, 0), 1)
    }

    /// 关键词扫描 armed。**只管宽度** —— 「宽 = 在扫描」「高 = 在采集」
    /// 是两根独立的轴，所以先开哪个模式都不影响结果。
    func setArmed(_ armed: Bool) {
        model.armed = armed
    }

    var debugArmed: Bool { model.armed }

    // MARK: - 窗口

    private func ensureWindow() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: OverlayGeometry.canvasWidth,
                                height: OverlayGeometry.canvasContentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // ⚠️ 必须关掉阴影。窗口是一块比可见胶囊大得多的画布，
        // AppKit 的阴影会沿它的顶边在硬件刘海**上方**画出一条可见的缝。
        // 胶囊自己在内容里画阴影。
        panel.hasShadow = false
        // NSStatusWindowLevel = 25：盖过菜单栏，让这块黑读成刘海本身。
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true      // 永久 click-through
        panel.isMovable = false

        let host = FirstMouseHostingView(rootView: NotchOverlayView(model: model,
                                                                   actions: { [weak self] in
            self?.hoverActions
        }))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    /// 把岛停在首选屏的顶部居中，紧贴顶边，与刘海融为一体。
    private func position() {
        guard let panel = window, let screen = ScreenInfo.preferred() else { return }

        let frame = screen.frame
        let inset = ScreenInfo.topInset(screen)
        let notch = ScreenInfo.notchWidth(screen)
        model.topInset = inset
        model.notchWidth = notch

        guard currentScreenFrame != frame else { return }
        currentScreenFrame = frame

        let width = OverlayGeometry.canvasWidth
        let height = OverlayGeometry.canvasHeight(topInset: inset)
        let x = (frame.origin.x + frame.width / 2 - width / 2).rounded()
        // Cocoa 是左下原点：贴顶 = 屏幕顶边减去画布高。
        let y = frame.origin.y + frame.height - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    /// 供验证脚本读取的当前几何。
    var debugFrame: NSRect? { window?.frame }
    var debugIsCompact: Bool { model.compact }
    var debugMessage: String { model.message }
    var debugTitle: String { model.title ?? "" }
    var debugState: String { model.state.rawValue }
    var debugHover: String { "\(model.hover)" }
    var debugAcceptsClicks: Bool { window?.ignoresMouseEvents == false }
    /// 胶囊在屏幕坐标里的矩形。自测拿它算按钮该点哪儿。
    var debugCapsuleRect: NSRect? {
        guard let frame = window?.frame else { return nil }
        return OverlayGeometry.capsuleRect(canvas: frame, capsule: model.capsule)
    }

    /// 实测的刘海宽 + 由它算出的胶囊尺寸。
    /// Tauri 版读不到真实刘海宽（`auxiliaryTopLeftArea` 是 Swift-only API），
    /// 只能硬编码 184 —— 这里能看出真值与它差多少。
    var debugCapsule: String {
        let c = model.capsule
        return String(format: "notchWidth=%.0f(硬编码回落=%.0f) inset=%.0f capsule=%.0fx%.0f",
                      model.notchWidth, OverlayGeometry.estimatedNotchWidth,
                      model.topInset, c.width, c.height)
    }
}

/// 刘海要画的内容。用 `@Observable` 而不是事件字符串 ——
/// 这一层在 Tauri 版是 20 个 `overlay://*` 事件，原生版直接绑定。
@MainActor
@Observable
final class NotchModel {
    var state: OverlayState = .idle
    var message: String = ""
    var title: String?
    var level: Double = 0
    var visible = false
    var armed = false
    var compact = false
    var topInset: Double = 32
    var notchWidth: Double = OverlayGeometry.estimatedNotchWidth
    var hover: OverlayHoverResponse = .none
    var stripAvailable = false

    var capsule: CapsuleSize {
        OverlayGeometry.capsule(state: state, topInset: topInset,
                                notchWidth: notchWidth, armed: armed,
                                compact: compact, hoverStrip: hover == .strip)
    }
}

/// 借来收 hover 条上的点击。
///
/// overlay 是不激活的面板，永远不会成为 key window —— 默认情况下落在
/// 非 key 窗口上的第一次点击只会被拿去「让窗口变 key」，按钮收不到。
/// hover 条上的每一次点击都是**第一次**点击，所以这个 override 不是优化，
/// 是那三个按钮能不能用的前提。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchOverlayView: View {
    @Bindable var model: NotchModel
    /// 迟绑定：hover 条的动作在窗口建好之后才由宿主注入。
    let actions: () -> NotchOverlayController.HoverActions?

    /// 状态色。刘海永远浮在别人的窗口上，所以这套色**固定，不随系统明暗翻转**。
    /// 紫色是唯一的非墨色相，专留给「机器在思考」，不与转写的青混淆。
    private var tint: Color {
        switch model.state {
        case .idle, .cancelled: return Color(red: 0.70, green: 0.65, blue: 0.58) // #B3A794
        case .recording: return Color(red: 0.84, green: 0.35, blue: 0.29)        // #D65A4A 朱砂
        case .transcribing, .jarvisStandby, .jarvisListening:
            return Color(red: 0.44, green: 0.75, blue: 0.70)                     // #6FBFB2 青
        case .processing: return Color(red: 0.73, green: 0.55, blue: 0.88)       // #B98BE0 紫
        case .success, .jarvisResult: return Color(red: 0.44, green: 0.71, blue: 0.42)
        case .error, .jarvisError: return Color(red: 0.88, green: 0.64, blue: 0.23) // #E0A33A 琥珀
        case .jarvisPending: return Color(red: 0.84, green: 0.35, blue: 0.29)
        case .notePaused: return Color(red: 0.70, green: 0.65, blue: 0.58)
        }
    }

    /// 光晕强度是**状态固定**的，不是纯电平驱动：录音跟着实时音频呼吸，
    /// 而每个终止态给一个稳定强度 —— 失败在电平 0 时也要站得住，
    /// 取消/空操作则要读得很淡。
    private var haloOpacity: Double {
        switch model.state {
        case .recording, .jarvisListening: return 0.18 + model.level * 0.4
        case .error, .jarvisError: return 0.50
        case .cancelled: return 0.12
        case .notePaused: return 0.0
        case .success, .jarvisResult: return 0.34
        case .transcribing, .processing: return 0.32
        default: return 0.16
        }
    }

    private var isBand: Bool { model.state == .jarvisStandby }

    var body: some View {
        let capsule = model.capsule
        ZStack(alignment: .top) {
            // ⚠️ 展开 hover 条时窗口会临时收鼠标事件，而这块画布铺满了
            // 520×168。不关掉它的命中，胶囊之外那一大片透明区域会把
            // 菜单栏的点击全吃掉。
            Color.clear.allowsHitTesting(false)
            UnevenRoundedRectangle(
                bottomLeadingRadius: isBand ? 0 : 18,
                bottomTrailingRadius: isBand ? 0 : 18)
                // ⚠️ 纯黑。任何偏暖的近黑都会在硬件刘海边缘露出接缝。
                .fill(Color.black)
                .frame(width: capsule.width, height: capsule.height)
                .overlay(alignment: .top) { band(width: capsule.width) }
                .overlay(alignment: .bottom) { content(capsule: capsule) }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        }
        .frame(width: OverlayGeometry.canvasWidth,
               height: OverlayGeometry.canvasHeight(topInset: model.topInset),
               alignment: .top)
        // 普通状态 hover = 淡化让路；落笔胶囊反过来，展开条且**绝不淡化**
        // —— 淡化的按钮既难认也难点。
        .opacity(model.visible ? (model.hover == .dim ? 0.32 : 1) : 0)
        .animation(.spring(duration: 0.42, bounce: 0.12), value: capsule.height)
        .animation(.spring(duration: 0.32), value: capsule.width)
        .animation(.easeOut(duration: 0.2), value: model.visible)
        .animation(.easeOut(duration: 0.16), value: model.hover)
    }

    /// 刘海带：状态点在左翼，锁/标记在右翼，都在带内垂直居中，
    /// 绝不伸到刘海下面去。
    private func band(width: Double) -> some View {
        let bandHeight = model.topInset > 0 ? model.topInset : OverlayGeometry.bandHeight
        let wing = (width - model.notchWidth) / 2
        return HStack(spacing: 0) {
            Circle()
                .fill(tint)
                .frame(width: 11, height: 11)
                .shadow(color: tint.opacity(haloOpacity), radius: 7)
                .frame(width: max(wing, 44))
            Spacer(minLength: 0)
        }
        .frame(width: width, height: bandHeight)
    }

    /// 贾维斯的卡片状态：命令要用等宽字排，而且比正常两行多一条键盘提示。
    private var isCard: Bool {
        [.jarvisPending, .jarvisResult, .jarvisError].contains(model.state)
    }

    @ViewBuilder
    private func content(capsule: CapsuleSize) -> some View {
        if model.hover == .strip {
            hoverStrip(capsule: capsule)
        } else if isCard {
            jarvisCard(capsule: capsule)
        } else if model.compact {
            // 紧凑胶囊只排一行：计时。胶囊亮着就代表在录音，
            // 不必再写一遍「正在录音」—— 那既占高度又是废话。
            Text(model.message)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.945, green: 0.91, blue: 0.84))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.bottom, 7)
                .frame(width: capsule.width)
        } else if !isBand {
            VStack(spacing: 2) {
                if let title = model.title ?? defaultTitle {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.945, green: 0.91, blue: 0.84))
                }
                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.945, green: 0.91, blue: 0.84).opacity(0.62))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(width: capsule.width)
        }
    }

    /// 命中关键词时掉下来的那张卡。
    ///
    /// 决策点在**执行之前**：3 秒倒计时期间 esc 撤销、↩ 立即执行。
    /// 命令用等宽字排 —— 用户要读的是一行 shell，不是散文。
    /// 执行失败时卡片不自动收，命令已经躺在剪贴板里（刘海 click-through，
    /// 没有按钮可点）。
    private func jarvisCard(capsule: CapsuleSize) -> some View {
        let paper = Color(red: 0.945, green: 0.91, blue: 0.84)
        return VStack(alignment: .leading, spacing: 6) {
            if let title = model.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.state == .jarvisError ? tint : paper)
            }
            Text(model.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(paper.opacity(0.86))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.state == .jarvisPending {
                HStack(spacing: 8) {
                    keyHint("esc", "撤销")
                    keyHint("↩", "立即执行")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: capsule.width, alignment: .leading)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 9.5))
        }
        .foregroundStyle(Color(red: 0.945, green: 0.91, blue: 0.84).opacity(0.66))
    }

    /// 鼠标停在落笔胶囊上时摊开的操作条。
    ///
    /// 三个动作都是「录着录着突然要做的事」：切一段、停一下、收工。
    /// 面板可能被挡在别人窗口后面，快捷键要记，而刘海一直在那儿。
    ///
    /// （spec/07 §6 的条是 [拆出][暂停·继续][停止]。**拆出还没做**（#21），
    /// 摆一个点了没反应的按钮比不摆更糟，所以先放切段 —— 它今天就能用，
    /// 而且和融合柱里的那组按钮是同一套。）
    private func hoverStrip(capsule: CapsuleSize) -> some View {
        let paused = model.state == .notePaused
        return HStack(spacing: 6) {
            stripButton("scissors", "切段") { actions()?.cut() }
                .disabled(paused)
                .opacity(paused ? 0.35 : 1)
            stripButton(paused ? "play.fill" : "pause.fill", paused ? "继续" : "暂停") {
                actions()?.togglePause()
            }
            stripButton("stop.fill", "停止", danger: true) { actions()?.stop() }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(width: capsule.width)
    }

    private func stripButton(_ icon: String, _ label: String,
                             danger: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(danger ? Color(red: 0.84, green: 0.35, blue: 0.29)
                                    : Color(red: 0.945, green: 0.91, blue: 0.84))
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var defaultTitle: String? {
        switch model.state {
        case .idle: return "落音 Inkfall"
        case .recording: return "正在录音"
        case .transcribing: return "正在转写"
        case .processing: return "正在加工"
        case .success: return "已完成"
        case .cancelled: return "已取消"
        case .error: return "请求失败"
        case .notePaused: return "已暂停"
        default: return nil
        }
    }
}
