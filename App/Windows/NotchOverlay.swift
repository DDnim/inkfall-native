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

    func show(state: OverlayState, message: String = "", title: String? = nil) {
        model.state = state
        model.message = message
        model.title = title
        ensureWindow()
        position()
        window?.orderFrontRegardless()
        model.visible = true
    }

    func hide() {
        model.visible = false
        window?.orderOut(nil)
    }

    var isVisible: Bool { model.visible }

    /// 录音电平（0…1）。呼吸带的幅度直接跟着它走。
    func setLevel(_ level: Double) {
        model.level = min(max(level, 0), 1)
    }

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

        let host = NSHostingView(rootView: NotchOverlayView(model: model))
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
    var noteCapsule = false
    var topInset: Double = 32
    var notchWidth: Double = OverlayGeometry.estimatedNotchWidth

    var capsule: CapsuleSize {
        OverlayGeometry.capsule(state: state, topInset: topInset,
                                notchWidth: notchWidth, armed: armed,
                                noteCapsule: noteCapsule)
    }
}

struct NotchOverlayView: View {
    @Bindable var model: NotchModel

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
            Color.clear
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
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(duration: 0.42, bounce: 0.12), value: capsule.height)
        .animation(.spring(duration: 0.32), value: capsule.width)
        .animation(.easeOut(duration: 0.2), value: model.visible)
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

    @ViewBuilder
    private func content(capsule: CapsuleSize) -> some View {
        if !isBand {
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
