import AppKit
import InkfallCore

/// 刘海岛该停在哪块屏、那块屏的刘海有多大。
enum ScreenInfo {

    /// 刘海岛属于刘海，所以**内置屏优先**；没有内置屏才跟随鼠标所在屏。
    ///
    /// ⚠️ 融合柱也用这个「首选屏」，而不是笔记窗当前所在的显示器 ——
    /// 否则笔记窗在外接屏时，柱子会 dock 到外接屏，而胶囊在内置屏。
    static func preferred() -> NSScreen? {
        let screens = NSScreen.screens
        if let builtIn = screens.first(where: isBuiltIn) { return builtIn }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }

    /// 顶部安全区 —— 刘海（或菜单栏安全区）从顶边往下伸多少。无刘海屏为 0。
    static func topInset(_ screen: NSScreen) -> Double {
        Double(screen.safeAreaInsets.top)
    }

    /// 硬件刘海的**真实**宽度。
    ///
    /// `auxiliaryTopLeftArea` 是 Swift-only API —— Tauri 版的 Rust 读不到，
    /// 只能硬编码 184pt。原生版可以读真值，这是重写直接拿到的改善。
    /// 读不到（无刘海、或系统没给）时回落到那个估计值。
    static func notchWidth(_ screen: NSScreen) -> Double {
        guard topInset(screen) > 0 else { return 0 }
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return OverlayGeometry.estimatedNotchWidth
        }
        // 刘海 = 屏宽减掉左右两块可用区域。
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? Double(width) : OverlayGeometry.estimatedNotchWidth
    }
}
