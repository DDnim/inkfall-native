import Foundation

/// 一次录音的文本去向。与「要不要扫关键词」是**两个独立的轴**。
///
/// 贾维斯原本*是*一个 sink，所以它和落笔永远不能同时开；改成 filter 之后
/// `noteWindow + scanning` 成为合法状态。这个正交性是核心不变量，
/// 见 inkfall-docs/spec/01-desktop-behavior.md §1。
public enum OutputSink: Sendable, Equatable {
    /// 粘贴到前台 App（经典听写）。
    case paste
    /// 落进落笔面板，绝不外粘。
    case noteWindow
    /// 什么都不留。纯扫描会话用；拆除过程中也会短暂处于这个状态。
    case discard
}

/// 一段被切出来的音频最终去哪。
public enum TakeDestination: Sendable, Equatable {
    case paste
    case note
    case discard
}

public struct TakeRouting: Sendable, Equatable {
    public let scanForCommand: Bool
    public let destination: TakeDestination

    public init(scanForCommand: Bool, destination: TakeDestination) {
        self.scanForCommand = scanForCommand
        self.destination = destination
    }
}

/// `RecState` 里决定「下一次按键做什么」的那一小片，抽成值类型，
/// 这样多步场景可以在单测里走完 —— 协调器本身需要活的 App 环境，测不了。
public struct SessionShape: Sendable, Equatable {
    public var recording: Bool
    public var hold: Bool
    public var sink: OutputSink
    /// 关键词扫描已 armed。本轮不实现扫描功能本身，但这个轴保留在类型里：
    /// 去掉它意味着以后加回来要重写状态机和全部测试。
    public var scanning: Bool

    public init(recording: Bool = false, hold: Bool = false,
                sink: OutputSink = .paste, scanning: Bool = false) {
        self.recording = recording
        self.hold = hold
        self.sink = sink
        self.scanning = scanning
    }

    public static let idle = SessionShape()
}

/// 按下落笔键（⌥Space）该做什么。
public enum NoteToggle: Sendable, Equatable {
    /// 笔记录音在飞：停止。
    case stop
    /// 刚起头的 hold 听写占着麦：转成笔记录音。
    case convertHold
    /// 纯扫描会话在跑：把笔记 sink 挂上去，两者共跑。
    case attachToScan
    /// 真听写占着麦：说明原因，别静默失败。
    case busyDictating
    /// 空闲：开始。
    case start
}

public enum SessionMachine {

    /// `scanning` 决定要不要扫，sink 决定文本去哪 —— 刻意正交。
    public static func routeTake(sink: OutputSink, scanning: Bool) -> TakeRouting {
        let destination: TakeDestination
        switch sink {
        case .paste: destination = .paste
        case .noteWindow: destination = .note
        case .discard: destination = .discard
        }
        return TakeRouting(scanForCommand: scanning, destination: destination)
    }

    public static func noteToggle(_ shape: SessionShape) -> NoteToggle {
        if shape.recording && shape.sink == .noteWindow { return .stop }
        if shape.recording && shape.hold { return .convertHold }
        if shape.recording && shape.scanning && shape.sink == .discard { return .attachToScan }
        if shape.recording { return .busyDictating }
        return .start
    }

    /// 把动作作用回形状上。
    ///
    /// 有了它多步场景才走得动：单步的动作表只回答「这一下该干什么」，
    /// 而真正会出事的是**几步之后**的状态 —— 「共跑时停掉笔记，麦克风还开着吗」
    /// 这种问题，一步一步断言是断言不出来的。
    ///
    /// ⚠️ 这不是「随便加的辅助函数」：`recording` 是引用计数的结果，
    /// 写错就等于要么把麦克风卡在开着，要么把另一个消费者从句子中间切断。
    public static func apply(_ toggle: NoteToggle, to shape: SessionShape) -> SessionShape {
        var next = shape
        switch toggle {
        case .stop:
            // 笔记这个消费者放手了；扫描还在的话流要留着（引用计数）。
            if let sink = sinkAfterRelease(otherConsumerActive: shape.scanning) {
                next.sink = sink
            } else {
                next.recording = false
                next.sink = .paste
            }
            next.hold = false
        case .convertHold:
            // 刚起头的 hold 听写变成笔记录音：同一条流换个去向。
            next.hold = false
            next.sink = .noteWindow
        case .attachToScan:
            // 纯扫描会话上挂一个 sink，两者共跑。
            next.sink = .noteWindow
        case .busyDictating:
            // 真听写占着麦：**一个字段都不许动**。
            break
        case .start:
            next.recording = true
            next.hold = false
            next.sink = .noteWindow
        }
        return next
    }

    /// 按一次 ⌥Space。
    public static func pressNote(_ shape: SessionShape) -> SessionShape {
        apply(noteToggle(shape), to: shape)
    }

    /// 一个消费者放开这条流之后，recorder 该怎么办 —— 就是引用计数。
    /// 写错的后果是要么把麦克风卡在开着，要么把另一个消费者从句子中间切断。
    ///
    /// - Returns: `.some(sink)` 表示保持录音并换成该 sink；`nil` 表示真正停掉。
    public static func sinkAfterRelease(otherConsumerActive: Bool) -> OutputSink? {
        otherConsumerActive ? .discard : nil
    }

    /// 共享的停顿切段器能不能拆。**切段是关键词可见的前提**，所以只要还有扫描在跑，
    /// 无论哪个消费者要求停止，切段器都必须留着。
    public static func mayStopSegmenter(scanning: Bool) -> Bool {
        !scanning
    }

    /// 命中关键词的那一段仍然落进笔记（不能悄悄扣下用户说过的话），
    /// 但它是**指令**不是口述正文，所以标出来；同时预标为已粘贴 ——
    /// 命令已经跑了，没有东西可粘。
    public static func noteBody(transcript: String, wasCommandHit: Bool) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return wasCommandHit ? ">> \(text)" : text
    }
}
