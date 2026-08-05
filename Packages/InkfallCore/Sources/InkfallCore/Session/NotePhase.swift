import Foundation

/// 落笔会话的三个阶段。
///
/// ⚠️ **暂停不等于结束**（spec/10 A11）。暂停时麦克风真的停了，但会话还开着：
/// 同一篇笔记、同一个粘贴目标、同一把语言锁，`resume` 接着往下录。
/// 把暂停当成「停止」会让继续录音时新起一篇，用户以为丢了半场。
public enum NotePhase: String, Sendable, Equatable, CaseIterable {
    /// 停下来了，正文可编辑（markdown 编辑器）。
    case editing
    /// 麦克风在收音。
    case recording
    /// 麦克风停了，会话仍然开着。
    case paused
}

/// 会让阶段发生变化的几件事。
public enum NotePhaseEvent: String, Sendable, Equatable, CaseIterable {
    case start, pause, resume, stop
    /// 关闭面板。隐私规则：面板一关就停止录音，但要**优雅**停 ——
    /// 在飞的段照常转写保存（A11）。
    case closePanel
}

public enum NoteSessionMachine {

    /// 合法转移；`nil` = 这一步不该发生，调用方原地忽略（**不是**报错，
    /// 重复按停止、在编辑态按继续都属于正常的手抖）。
    public static func next(_ phase: NotePhase, on event: NotePhaseEvent) -> NotePhase? {
        switch (phase, event) {
        case (.editing, .start): return .recording
        case (.recording, .pause): return .paused
        case (.paused, .resume): return .recording
        // 停止从「在录」和「暂停中」都走得通 —— 暂停期间按停止是常见操作。
        case (.recording, .stop), (.paused, .stop): return .editing
        // 关面板 = 停止录音（隐私）。已经停下来的则什么都不做。
        case (.recording, .closePanel), (.paused, .closePanel): return .editing
        default: return nil
        }
    }

    /// 麦克风该不该在收音。
    public static func microphoneLive(_ phase: NotePhase) -> Bool { phase == .recording }

    /// 会话还开着 —— 正文只读、不许换篇、语言锁不重置。
    ///
    /// ⚠️ 判「只读 / 不许换篇 / 正文由段落合成」要的都是**这个**，不是
    /// `microphoneLive`：暂停期间让用户去编辑草稿，会在继续录音的那一刻
    /// 被段落合成悄悄冲掉。
    public static func isLive(_ phase: NotePhase) -> Bool { phase != .editing }
}
