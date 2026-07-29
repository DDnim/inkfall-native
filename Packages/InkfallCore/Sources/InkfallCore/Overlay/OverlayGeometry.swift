import CoreGraphics
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
    /// 只在鼠标真的停上来时才撑到这个高度 —— 平时那条不在，
    /// 白留 8pt 就是白占屏幕顶部。
    public static let noteHoverStripSpan: Double = 38
    /// 紧凑胶囊在带之下的内容高。
    ///
    /// 比普通状态的 `contentHeight`(60) 矮一半：普通状态排两行
    /// （「正在录音」+ 副行文案），紧凑胶囊只排一行 —— 胶囊亮着本身
    /// 就代表在录音，再写一遍「正在录音」是白占高度。
    /// 录音期间（按住说话与落笔）都用它；转写/加工/结果那些状态仍排两行，
    /// 因为那时标题（「正在转写」）是真信息。
    public static let compactContentHeight: Double = 30

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
    ///   - compact: 紧凑胶囊（只排一行，用于录音中）。
    ///   - hoverStrip: 正在展开 hover 条（只对紧凑胶囊有意义）。
    public static func capsule(state: OverlayState,
                               topInset: Double,
                               notchWidth: Double,
                               armed: Bool,
                               compact: Bool = false,
                               hoverStrip: Bool = false) -> CapsuleSize {
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

        // 紧凑胶囊：只排一行（计时），所以比普通状态矮一截。
        // 鼠标停上来时那一行换成 hover 条（[切段][暂停/继续][停止]），
        // 要撑到 `noteHoverStripSpan` 才放得下，否则条的下半截会被裁掉。
        if compact {
            let content = hoverStrip ? noteHoverStripSpan : compactContentHeight
            size = CapsuleSize(width: size.width, height: content + topInset)
        }
        return size
    }

    /// 胶囊在画布里的位置：**贴顶居中**。
    ///
    /// 悬停命中判的是这个矩形，不是整块画布 —— 画布 520×168 里绝大部分是
    /// 透明的，拿它当热区会让鼠标一飘到屏幕顶端就触发。
    ///
    /// - Parameter canvas: overlay 窗口在屏幕坐标里的 frame（Cocoa 左下原点）。
    public static func capsuleRect(canvas: CGRect, capsule: CapsuleSize) -> CGRect {
        CGRect(x: canvas.midX - capsule.width / 2,
               y: canvas.maxY - capsule.height,
               width: capsule.width,
               height: capsule.height)
    }
}
