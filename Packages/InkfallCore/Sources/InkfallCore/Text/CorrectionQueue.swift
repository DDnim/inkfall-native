import Foundation

/// 边听边插话：一口气说了一串错话，纠正一句接一句念，不扔（2026-10-01 境：「我说一长串错误的话，他就只插一句嘴」）。
///
/// 原来靠 4 秒冷却防「同一口气插两句」，结果念第一句的期间准备好的纠正全被冷却吃掉。
/// 现在念的期间来的纠正排在后面，念完接着念；排太久的话题已经过去了，扔掉。
public struct CorrectionQueue: Sendable {

    /// 排队超过这么久就不念了（这时对方多半已经聊到别处）。
    public static let maxWait: TimeInterval = 8
    /// 最多排几句（再多就是在念检讨书了）。
    public static let capacity = 3

    public struct Item: Sendable, Equatable {
        public let correction: String
        public let spoken: String
        public let queuedAt: Date
    }

    private var items: [Item] = []

    public init() {}

    public var count: Int { items.count }

    /// 排进去；满了就挤掉最早的那句。
    public mutating func push(correction: String, spoken: String, now: Date) {
        items.append(Item(correction: correction, spoken: spoken, queuedAt: now))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }

    /// 下一句要念的（等太久的扔掉）。
    public mutating func pop(now: Date) -> Item? {
        items.removeAll { now.timeIntervalSince($0.queuedAt) > Self.maxWait }
        return items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }
}
