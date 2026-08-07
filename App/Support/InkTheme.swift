import SwiftUI

/// 「墨与纸」token 层。与设计集 00 号 sheet 一一对应。
///
/// 纸/墨用 ramp 而不是四个手调的近似色：新表面从 ramp 里派生。
/// 强调色**按职责**分工（朱砂=主操作、青碧=开启/正常、赭=需注意、危=破坏），
/// 而不是按功能分（那样每加一个功能就要再挑一个色）。
public enum Ink {

    // 纸 · 0 = 最远，5 = 最近读者
    public static let paper0 = Color(hex: 0xE4D9BE, dark: 0x15110C)
    public static let paper1 = Color(hex: 0xEFE6D2, dark: 0x1B1610)
    public static let paper2 = Color(hex: 0xF6EFDF, dark: 0x211C16)
    public static let paper3 = Color(hex: 0xFBF5E9, dark: 0x2A241C)
    public static let paper4 = Color(hex: 0xFFFDF6, dark: 0x332C22)

    // 墨 · 1 = 正文，4 = 占位/禁用
    public static let ink1 = Color(hex: 0x241F18, dark: 0xF1E8D6)
    public static let ink2 = Color(hex: 0x5B5142, dark: 0xD3C7AE)
    public static let ink3 = Color(hex: 0x8A7E6A, dark: 0xB6A98F)
    public static let ink4 = Color(hex: 0xB3A794, dark: 0x8A7E6A)

    public static let hair = Color(hex: 0x46341C, dark: 0xD6C6AA).opacity(0.16)

    // 强调 · 一色一职
    public static let cinnabar = Color(hex: 0xC0392B, dark: 0xD65A4A)   // 主操作 / 品牌 / 录音
    public static let teal = Color(hex: 0x2A7F72, dark: 0x4FB3A2)       // 焦点 / 开启 / 正常
    public static let amber = Color(hex: 0xB4770E, dark: 0xD9A441)      // 需注意，不危险
    public static let danger = Color(hex: 0xB23B2E, dark: 0xE06A5C)     // 删除 / 清空

    /// 墨锭 —— **贴着刘海的那一套固定深色，不随系统主题翻转**。
    /// 胶囊必须是纯黑：任何偏暖的近黑都会在硬件刘海边缘露出一条接缝。
    /// （`NotchOverlay` 自己写死了同样的黑与米，不走这两个常量；引导页走。）
    public static let inkBlock = Color.black
    public static let paperOnInk = Color(hex: 0xF1E8D6, dark: 0xF1E8D6)

    /// 落笔面板（那扇悬浮窗）的表面与前景。
    ///
    /// 和上面那套**分开**：面板不贴着刘海，就是一扇正常的窗，跟随系统明暗。
    /// 深色的两个值是原来那道渐变的原值，浅色下是暖纸。
    public static let panelTop = Color(hex: 0xFDF8EC, dark: 0x16110C)
    public static let panelBottom = Color(hex: 0xF0E6D2, dark: 0x0A0805)

    /// 面板上的前景色。面板里所有层级都是**这一个值加不同的 opacity** 叠出来的
    /// （正文 1.0、次要 0.5、分隔线 0.12…），所以只要它翻转，整套明暗就都成立 ——
    /// 不需要给每一处再配一个浅色值。
    public static let panelInk = Color(hex: 0x241F18, dark: 0xF1E8D6)

    // 圆角
    public static let rSM: CGFloat = 5
    public static let rMD: CGFloat = 8
    public static let rLG: CGFloat = 12
    public static let rXL: CGFloat = 16
}

extension Color {
    /// 明暗两套值。SwiftUI 的 `Color` 没有直接的动态构造，
    /// 借 `NSColor` 的 appearance-aware 初始化。
    init(hex light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
