import Foundation

/// 刘海岛（墨锭）的可见状态。
public enum OverlayState: String, Sendable, CaseIterable {
    case idle
    case recording
    case transcribing
    case processing
    case success
    case cancelled
    case error
    /// 待命只占刘海带，绝不下坠。
    case jarvisStandby
    /// 待命时听到声音：掉成 pill（宽度不变，只长高）。
    case jarvisListening
    /// 命中关键词：卡片掉出来，带可撤销的倒计时。
    case jarvisPending
    /// 命令已执行：矮一档（没有键盘提示行）。
    case jarvisResult
    /// 执行失败：与命中卡同高，但停着不自动收。
    case jarvisError
    /// 落笔已暂停：与录音 pill 同尺寸，靠灰化与冻结的计时区分。
    case notePaused
}

public struct CapsuleSize: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 刘海岛的几何。
///
/// **窗口尺寸永不变**：它是一块固定画布，可见的胶囊在里面变形。因为 overlay
/// 永久 click-through，多出来的透明区域挡不住任何东西 —— 「先长大窗口再展开、
/// 先收缩再缩小窗口」这套编排因此免费。
///
/// 形状由**两个独立的轴**决定：
/// - **宽度** ← 关键词扫描是否 armed
/// - **高度** ← 是否真的在采集（录音 sink，或待命时有语音进来）
///
/// 两者读的是独立输入，所以先开哪个模式都不影响结果。
public enum OverlayGeometry {

    /// 刘海两侧各一块，放状态点 / 锁 / 标记。
    /// 44 → 胶囊 184 + 2×44 = 272pt，也就是融合柱的宽度。
    public static let notchWingWidth: Double = 44
    /// 刘海 MacBook 面板的摄像头区宽度。
    ///
    /// Tauri 版只能硬编码这个值（`NSScreen.auxiliaryTopLeftArea` 是 Swift-only
    /// API，Rust 读不到）。**原生版可以读真值** —— 见 `Screen.notchWidth`，
    /// 这里的常量只作为读不到时的回落。
    public static let estimatedNotchWidth: Double = 184
    /// 无刘海屏的回落宽度。
    public static let overlayWidth: Double = 320
    /// pill 在刘海带之下的内容高。
    public static let contentHeight: Double = 60
    /// 无刘海屏的合成带高。
    public static let bandHeight: Double = 32
    /// 扫描 armed 时的带宽。
    public static let jarvisBandWidth: Double = 420
    public static let jarvisCardWidth: Double = 520
    /// 带之下：9 + 标题 18 + 6 + 命令 29 + 6 + 提示 14 + 12。
    public static let jarvisPaneHeight: Double = 96
    /// 同上，减掉键盘提示行与它的间距 —— 结果卡不需要回答。
    public static let jarvisResultPaneHeight: Double = 74
    /// 落笔胶囊在带之下预留给 hover 条的空间（30pt 的条 + 8pt 余量）。
    public static let noteHoverStripSpan: Double = 38

    /// 画布：按最大的那个状态定尺寸，永不改变。
    public static let canvasWidth: Double = jarvisCardWidth
    public static let canvasContentHeight: Double = 136

    public static func canvasHeight(topInset: Double) -> Double {
        canvasContentHeight + topInset
    }

    /// 某个状态该画多大的胶囊。
    ///
    /// - Parameters:
    ///   - topInset: 屏幕顶部安全区（刘海高度）；无刘海屏为 0。
    ///   - notchWidth: 硬件刘海宽度；无刘海屏为 0。
    ///   - armed: 关键词扫描是否 armed。
    ///   - noteCapsule: 是否是落笔胶囊（要给 hover 条留位置）。
    public static func capsule(state: OverlayState,
                               topInset: Double,
                               notchWidth: Double,
                               armed: Bool,
                               noteCapsule: Bool = false) -> CapsuleSize {
        let hasNotch = topInset > 0 && notchWidth > 0
        // 承载状态点与电平的带。无刘海屏给一个等高的合成带，
        // 这样卡片在哪儿都是同一个排版。
        let band = topInset > 0 ? topInset : bandHeight
        let hugging = hasNotch ? notchWidth + 2 * notchWingWidth : overlayWidth
        // armed 会加宽所有非卡片状态；卡片有自己的宽度。
        let width = armed ? max(jarvisBandWidth, hugging) : hugging

        var size: CapsuleSize
        switch state {
        case .jarvisPending, .jarvisError:
            size = CapsuleSize(width: jarvisCardWidth, height: band + jarvisPaneHeight)
        case .jarvisResult:
            size = CapsuleSize(width: jarvisCardWidth, height: band + jarvisResultPaneHeight)
        case .jarvisStandby:
            // 还什么都没采集：宽（扫描 armed），但**完全不下坠** ——
            // 空闲的待命必须让开路，包括在没有刘海可以藏的屏幕上，
            // 那里一个完整的 pill 会变成横在顶部的一条永久黑带。
            size = CapsuleSize(width: width, height: band)
        default:
            size = CapsuleSize(width: width, height: contentHeight + topInset)
        }

        // 落笔胶囊要给 hover 条（[拆出][暂停/继续][停止]）留位置。条贴在带的下沿、
        // 约 30pt 高，所以一个普通录音 pill（60pt，或无刘海屏的 32pt 带）会把它
        // 的底部切掉。把画的矩形做这么高，同时也把 hover 命中区扩到够得着条。
        if noteCapsule {
            size = CapsuleSize(width: size.width,
                               height: max(size.height, band + noteHoverStripSpan))
        }
        return size
    }
}
