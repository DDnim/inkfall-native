import CoreGraphics

/// 鼠标停在刘海岛上时该发生什么。
public enum OverlayHoverResponse: Sendable, Equatable {
    /// 没停在胶囊上。
    case none
    /// 普通状态：整体淡化，让下面的东西可读。
    case dim
    /// 落笔胶囊：展开 hover 条（切段 / 暂停·继续 / 停止），**绝不淡化**。
    case strip
}

public enum OverlayHover {

    /// - Parameters:
    ///   - hovering: 鼠标是否落在**当前绘制的胶囊矩形**内（不是画布）。
    ///   - stripAvailable: 这一刻有没有 hover 条可展开。只有长录会话有；
    ///     按住说话同样是紧凑胶囊，但那时手正按着键，条上的按钮一个都用不上。
    public static func response(hovering: Bool, stripAvailable: Bool) -> OverlayHoverResponse {
        guard hovering else { return .none }
        // 落笔反过来：普通状态 hover 是「让路」，落笔 hover 是「摊开操作」。
        // 淡化的按钮既难认也难点，所以这两件事必须互斥。
        return stripAvailable ? .strip : .dim
    }

    /// 这个响应要不要临时关掉 click-through。
    ///
    /// ⚠️ 只有 `.strip` 要。其余一切情况都必须放回 click-through ——
    /// overlay 卡在「接受点击」是能把整个屏幕顶端点死的，而且用户完全
    /// 看不出是谁在吃他的点击。
    public static func wantsMouseEvents(_ response: OverlayHoverResponse) -> Bool {
        response == .strip
    }
}
