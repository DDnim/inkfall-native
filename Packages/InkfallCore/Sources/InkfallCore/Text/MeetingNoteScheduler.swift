import Foundation

/// 自动会议笔记的**合批调度**。
///
/// 这是整个功能里最容易写错、也最要紧的一段逻辑。会议笔记那一轮加工要把
/// 「已有笔记 + 新内容」整个喂给模型，比逐段加工慢一个量级（十几秒起）；
/// 而落笔的段是几秒一条。天真的做法「每段跑一次」会立刻排起一条永远追不上
/// 的队，越开越长，笔记越来越滞后。
///
/// 所以规则是**合批**：上一轮还在跑时，新来的段只是攒着；上一轮一结束，
/// 把攒下的**所有**内容合成一次跑掉。落后一轮，但永远不会积压两轮。
///
/// ⚠️ 三条不变量：
/// 1. 同一时刻只有一轮在飞（`isRunning`）
/// 2. 攒着的内容**一条都不能丢** —— 每一段要么在 `pending` 里，要么已经进了
///    某一批
/// 3. 一轮结束时如果有积压，**立刻**接着跑，不等下一段来触发
public struct MeetingNoteScheduler: Sendable, Equatable {

    /// 会话累计到这么多字才值得建第一份会议笔记。
    /// 太早建会得到一份「张三说了你好」的笔记，纯属噪声。
    public static let firstBatchCharacters = 100

    /// 还没送出去的段，按说话顺序。
    public private(set) var pending: [String] = []
    /// 有一轮加工正在飞。
    public private(set) var isRunning = false
    /// 会话至今累计的字数（含已经送出去的）。
    public private(set) var totalCharacters = 0
    /// 第一批已经送出去过了 —— 之后不再受字数门槛限制。
    public private(set) var startedFirstBatch = false

    public init() {}

    /// 新的一段落地了。
    ///
    /// - Returns: 现在就该送出去的批次；`nil` = 攒着（上一轮没跑完，
    ///   或者还没够第一批的字数门槛）。
    public mutating func append(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        pending.append(trimmed)
        totalCharacters += trimmed.count
        return takeBatchIfPossible()
    }

    /// 上一轮加工结束了（成功或失败都要调）。
    ///
    /// - Returns: 积压的那一批（合成一次）；`nil` = 没有积压。
    public mutating func finish() -> String? {
        isRunning = false
        return takeBatchIfPossible()
    }

    /// 会话结束：把剩下的一次跑完，**不再看字数门槛**。
    /// 一场只说了 80 个字的短会也该有它的笔记。
    ///
    /// - Returns: 要跑的最后一批；`nil` = 没有积压，或者还有一轮在飞
    ///   （那一轮结束时 `finish()` 会把积压带走）。
    public mutating func flush() -> String? {
        guard !isRunning, !pending.isEmpty else { return nil }
        return take()
    }

    /// 还有没有没落进笔记的内容 —— 面板上「还在整理」的依据。
    public var hasOutstandingWork: Bool { isRunning || !pending.isEmpty }

    private mutating func takeBatchIfPossible() -> String? {
        guard !isRunning, !pending.isEmpty else { return nil }
        // 第一批要够字数；之后每一批来者不拒。
        guard startedFirstBatch || totalCharacters >= Self.firstBatchCharacters else {
            return nil
        }
        return take()
    }

    private mutating func take() -> String {
        let batch = pending.joined(separator: "\n\n")
        pending.removeAll()
        isRunning = true
        startedFirstBatch = true
        return batch
    }
}
