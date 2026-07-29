import Foundation

/// 会话时长的记账。**暂停期间冻住**。
///
/// 直接用 `now - startedAt` 会把暂停的墙钟时间算进去：暂停十分钟回来，
/// 界面写着「已录 12:30」而音频里只有 2:30。那个数字是给用户判断
/// 「这段够不够长」用的，掺进墙钟就彻底失去意义。
///
/// 所以只累计**真正在录的那些区间**。
public struct SessionClock: Sendable, Equatable {

    /// 之前那些已经结束的录音区间的总时长。
    private var accumulated: TimeInterval = 0
    /// 当前这段录音是什么时候开始的。`nil` = 没在录（没起过，或正暂停）。
    private var runningSince: TimeInterval?
    private var started = false

    public init() {}

    /// 正暂停（起过录，但当前没在计时）。
    public var isPaused: Bool { started && runningSince == nil }

    /// 起一场新会话，把之前的账清零。
    public mutating func start(at now: TimeInterval) {
        accumulated = 0
        runningSince = now
        started = true
    }

    /// 暂停。已经暂停时是空操作 —— 暂停有好几个入口
    /// （hover 条、面板按钮、快捷键），谁都可能重复按。
    public mutating func pause(at now: TimeInterval) {
        guard let since = runningSince else { return }
        accumulated += now - since
        runningSince = nil
    }

    public mutating func resume(at now: TimeInterval) {
        guard started, runningSince == nil else { return }
        runningSince = now
    }

    public mutating func reset() {
        accumulated = 0
        runningSince = nil
        started = false
    }

    /// 到 `now` 为止真正录了多久。
    public func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + (now - since)
    }
}
