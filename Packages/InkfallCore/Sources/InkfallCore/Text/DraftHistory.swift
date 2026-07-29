import Foundation

/// 笔记正文的撤销栈。
///
/// ## 为什么要自己存快照，而不是用 NSTextView 的撤销
///
/// 编辑器用的是 HighlightedTextEditor，它的 `updateNSView` **每次都**执行
/// `view.attributedText = highlighted`，落到 `textStorage.setAttributedString()`
/// 是一次整体替换。而用户每敲一个字都会走一遍
/// 「textDidChange → 绑定回写 → SwiftUI 重渲染 → updateNSView」的往返，
/// 于是每个字符都伴随一次整体替换 —— NSTextView 自带的 `allowsUndo`
/// 撤销栈会被打散，⌘Z 撤不出有意义的东西。
///
/// 所以撤销放在**文档层**：按时间合并的正文快照。粒度比逐字符粗
/// （连续打字算一步），但这恰恰是写笔记时想要的粒度。
public struct DraftHistory: Equatable, Sendable {

    /// 连续编辑多久之内算同一步。低于它的改动合并进上一个快照，
    /// 否则「撤销」会变成一个字一个字往回退，没人这么用。
    public static let coalesceSeconds: Double = 1.0
    /// 最多留多少步。一篇笔记的正文可以很长，无上限地留会把内存吃掉。
    public static let limit = 200

    private var past: [String] = []
    private var future: [String] = []
    /// 最近一次记录的时刻，用来判断合并窗口。
    private var lastRecordAt: Double?
    /// 当前已知的正文。`record` 拿它和新值比对，没变就什么都不做。
    private var current: String = ""

    public init(initial: String = "") {
        current = initial
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// 正文变了就喂进来。同一个合并窗口内的连续改动只留最早的那个快照。
    public mutating func record(_ text: String, at now: Double) {
        guard text != current else { return }
        let within = lastRecordAt.map { now - $0 < Self.coalesceSeconds } ?? false
        // 合并窗口内：`past` 顶上那个快照已经代表了这一步的起点，不再追加。
        if !within {
            past.append(current)
            if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        }
        // 新的编辑让重做分支失效 —— 标准的撤销语义。
        future.removeAll()
        current = text
        lastRecordAt = now
    }

    /// - Returns: 撤销后的正文；没有可撤销的就返回 nil。
    public mutating func undo() -> String? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        // 撤销之后立刻打字不该被合并进被撤销的那一步里。
        lastRecordAt = nil
        return previous
    }

    /// - Returns: 重做后的正文；没有可重做的就返回 nil。
    public mutating func redo() -> String? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        lastRecordAt = nil
        return next
    }

    /// 换了一篇笔记：整条历史作废，绝不能让 ⌘Z 把上一篇的正文倒进这一篇。
    public mutating func reset(to text: String) {
        past.removeAll()
        future.removeAll()
        lastRecordAt = nil
        current = text
    }
}
