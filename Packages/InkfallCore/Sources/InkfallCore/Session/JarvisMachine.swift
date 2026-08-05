import Foundation

/// ⌥, 按下之后该做什么（spec/01 §1.2）。
///
/// sink / scanning 那两根正交的轴、`routeTake`、`sinkAfterRelease`、
/// `mayStopSegmenter` 都在 `SessionMachine` 里 —— 那才是共用的会话骨架，
/// 这里只补上贾维斯自己的那一半。
public enum JarvisToggleAction: String, Sendable, Equatable {
    /// 功能没开：只提示，不改任何状态。
    case refuse
    /// 纯待命（sink=discard）时再按一次 = 整个会话结束。
    case stopRecording
    /// 还有别的消费者要这条流：只撤掉过滤器，录音继续。
    case disarmKeepRecording
    /// 把刚起头的 hold 听写转成待命会话。
    case convertHold
    /// 在已有会话（落笔）上叠加扫描。
    case armOverExisting
    /// 起一个 discard + scan 的新会话。
    case startStandby
}

public enum JarvisMachine {

    /// spec/01 §1.2 的动作表。**顺序即语义**，不要重排。
    public static func toggleAction(shape: SessionShape,
                                    featureEnabled: Bool) -> JarvisToggleAction {
        guard featureEnabled else { return .refuse }
        if shape.recording, shape.scanning, shape.sink == .discard { return .stopRecording }
        if shape.recording, shape.scanning { return .disarmKeepRecording }
        if shape.recording, shape.hold { return .convertHold }
        if shape.recording { return .armOverExisting }
        return .startStandby
    }

    /// 把动作作用回形状上 —— 多步场景靠它走（见 `SessionMachine.apply`）。
    public static func apply(_ action: JarvisToggleAction,
                             to shape: SessionShape) -> SessionShape {
        var next = shape
        switch action {
        case .refuse:
            // 功能没开：**一个字段都不许动**。
            break
        case .stopRecording:
            next.recording = false
            next.scanning = false
            next.hold = false
            next.sink = .paste
        case .disarmKeepRecording:
            // 只撤过滤器 —— 别的消费者还要这条流，正交性的全部意义。
            next.scanning = false
        case .convertHold:
            next.hold = false
            next.scanning = true
            next.sink = .discard
        case .armOverExisting:
            next.scanning = true
        case .startStandby:
            next.recording = true
            next.hold = false
            next.scanning = true
            next.sink = .discard
        }
        return next
    }

    /// 按一次 ⌥,。
    public static func pressJarvis(_ shape: SessionShape,
                                   featureEnabled: Bool = true) -> SessionShape {
        apply(toggleAction(shape: shape, featureEnabled: featureEnabled), to: shape)
    }

    /// 刘海上「这一段听到了什么」那一行：截断到 24 字加省略号。
    ///
    /// 未命中原本是静默丢弃，而那恰恰是最需要把原文说出来的一种结果 ——
    /// 只有看到它，用户才分得清关键词是**听错了**还是**没听见**。
    public static func takeResultLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > JarvisTiming.takeResultChars else { return trimmed }
        return String(trimmed.prefix(JarvisTiming.takeResultChars)) + "…"
    }
}

/// 贾维斯的全部时间常数（spec/01 §7）。**硬性**，改了就是改了行为。
public enum JarvisTiming {
    /// 误触发一条 shell 命令的代价是不对称的，所以决策点放在**执行之前**。
    public static let undoCountdownSeconds: Double = 3
    /// 待命时超过这个电平算「听到有人在说话」。
    public static let voiceLevel: Double = 0.06
    /// 安静多久才把 pill 收回带 —— 防止每个音节间隙都闪一下。
    public static let quietCollapseMs: Double = 1200
    /// 单次结果在刘海上停留多久。
    public static let takeResultHoldMs: Double = 2200
    /// 原文截断到多少字。
    public static let takeResultChars: Int = 24
    /// 命令执行完之后多久把卡片收回待命带。
    public static let resultHoldSeconds: Double = 2
    /// 撤销的删除线动画（约 820ms）跑完再收。
    public static let cancelledHoldSeconds: Double = 1
    /// 连续对话：粘完等一拍再敲回车，让目标先把文本收进输入框。
    public static let conversationReturnDelayMs: Double = 120
}

/// 待命 + 倒计时的记账。
///
/// 单独做成一个纯类型，是为了让 spec/10 **A12** 那条不变量可以被穷举测试钉住：
/// > 只在有待执行命令倒计时期间抢占 esc / ↩，任何结束扫描的转移都必须同时
/// > 清掉倒计时。遗留 = 用户的 Escape 键全系统失效且屏幕上没有任何解释。
public struct JarvisRuntime: Sendable, Equatable {
    /// 扫描 armed。
    public private(set) var scanning = false
    /// 正在倒计时的那条命令。nil = 没有倒计时 = **不抢占 esc / ↩**。
    public private(set) var pendingID: UInt64?
    /// 每条待执行命令的编号。过期的倒计时任务不能执行一条已经被撤销的命令。
    public private(set) var sequence: UInt64 = 0
    public private(set) var discarded: Int = 0

    public init() {}

    /// 热键监听器该不该抢占 esc / ↩。
    public var grabsEscapeAndReturn: Bool { pendingID != nil }

    public mutating func arm() {
        scanning = true
        discarded = 0
    }

    /// 结束扫描。**必须**同时清掉倒计时 —— 这就是 A12 那条不变量本身。
    public mutating func disarm() {
        scanning = false
        pendingID = nil
    }

    /// 登记一条待执行命令，返回它的编号。没在扫描时拒绝（返回 nil）——
    /// 「有倒计时 ⟹ 一定有正在运行的扫描」。
    public mutating func schedule() -> UInt64? {
        guard scanning else { return nil }
        sequence += 1
        pendingID = sequence
        return sequence
    }

    /// 倒计时到点 / 「立即执行」：只有还是当前那一条才算数。
    public mutating func take(id: UInt64) -> Bool {
        guard pendingID == id else { return false }
        pendingID = nil
        return true
    }

    /// 撤销。
    public mutating func cancel(id: UInt64) -> Bool { take(id: id) }

    public mutating func countDiscarded() -> Int {
        discarded += 1
        return discarded
    }
}
