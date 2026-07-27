import Foundation

/// 有序粘贴队列。
///
/// 转写是异步的：后提交的短录音可能先完成。按完成顺序粘贴就会把后说的话
/// 粘在前面。这个队列让粘贴严格按**提交顺序**发生：
///
/// - `enqueue()` 在停止录音 / 切段（= 提交）时刻分配单调递增的 `seq` 并占位。
/// - 转写照常异步；完成时调用 `complete(seq:item:)`（要粘）或 `skip(seq:)`
///   （不产生粘贴：编辑前发送 / 提问 / 失败）。
/// - `takeReadyPrefix()` 取队头**连续**的已完成段，按 seq 顺序返回并前移队头。
///   队头仍在 pending 就一个都不给 —— 后面的一律 hold，绝不插队。
///
/// 值类型，自身不做并发控制：持有者负责串行化访问，这样并发完成之间没有竞争。
public struct OrderedPasteQueue<Item: Sendable>: Sendable {

    private enum Slot: Sendable {
        /// 已提交，转写还没完成。
        case pending
        /// 转写完成，轮到它时粘贴。
        case ready(Item)
        /// 转写完成但不产生粘贴。只占着位保住顺序，然后被排掉。
        case skip
    }

    private var slots: [UInt64: Slot] = [:]
    private var nextSeq: UInt64 = 0
    /// 下一个允许粘贴的 seq（在它之前的都已处理完）。
    private var head: UInt64 = 0

    public init() {}

    /// 在提交时刻占一个位，返回它的 seq（即提交顺序）。
    @discardableResult
    public mutating func enqueue() -> UInt64 {
        let seq = nextSeq
        nextSeq += 1
        slots[seq] = .pending
        return seq
    }

    /// 标记某位可以粘贴。之后调 `takeReadyPrefix()` 取出现在可粘的那些。
    public mutating func complete(seq: UInt64, item: Item) {
        // 只覆盖仍然 pending 的位；忽略走失/重复的完成。
        if case .pending = slots[seq] { slots[seq] = .ready(item) }
    }

    /// 标记某位不产生粘贴，这样它不会把后面的挡住。
    public mutating func skip(seq: UInt64) {
        if case .pending = slots[seq] { slots[seq] = .skip }
    }

    /// 取出队头连续的已完成段（按 seq 顺序）并前移队头。
    /// 碰到仍在 pending（或缺失）的位就停 —— 绝不越过未完成的更早提交。
    public mutating func takeReadyPrefix() -> [Item] {
        var ready: [Item] = []
        while let slot = slots[head] {
            switch slot {
            case .pending:
                return ready
            case .ready(let item):
                ready.append(item)
                slots.removeValue(forKey: head)
                head += 1
            case .skip:
                slots.removeValue(forKey: head)
                head += 1
            }
        }
        return ready
    }

    /// 把序号（和队头）跳到 `seq` 之后。
    ///
    /// 启动时恢复了持久化的笔记会话就必须调它：恢复的段沿用上一轮的 id，
    /// 而一个从 0 开始的新队列会发出**撞车**的 id —— 新 take 会「原地更新」
    /// 一个已恢复的旧块（新内容渲染在旧笔记上方）而不是追加。
    public mutating func advancePast(_ seq: UInt64) {
        if nextSeq <= seq { nextSeq = seq + 1 }
        if head < nextSeq { head = nextSeq }
    }

    /// 还没排掉的位数（pending 或已完成但被 hold）。
    public var outstanding: Int { slots.count }
}
