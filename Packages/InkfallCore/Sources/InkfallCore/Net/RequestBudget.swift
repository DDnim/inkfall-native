import Foundation

/// 每分钟请求数的滑动窗口（客户端这边自己数）。
///
/// Groq 免费档的 whisper-large-v3-turbo 是 **20 次 / 分钟**（2026-09-30 实测 429：
/// 「requests per minute (RPM): Limit 20」），响应头里只给每天的额度，每分钟的得自己数。
/// 边听边插话每停顿 0.2 秒就想转写一次，热闹的对话一分钟能停几十次 ——
/// 所以停顿时的试探要给「一句话收尾」那次留余量（`allows(reserve:)`），超了就不试探，等 1.5 秒再收。
public struct RequestBudget: Sendable {

    public let limit: Int
    public let window: TimeInterval
    private var stamps: [Date] = []
    private var blockedUntil: Date?

    public init(limit: Int, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    public func remaining(now: Date) -> Int {
        if let blockedUntil, now < blockedUntil { return 0 }
        return max(0, limit - active(now: now).count)
    }

    /// 还剩的比 `reserve` 多才放行。
    public func allows(reserve: Int, now: Date) -> Bool {
        remaining(now: now) > reserve
    }

    public mutating func spend(now: Date) {
        stamps = active(now: now)
        stamps.append(now)
    }

    /// 服务端回了 429：不管自己怎么算，等它说的时间。
    public mutating func block(until date: Date) {
        blockedUntil = max(blockedUntil ?? date, date)
    }

    /// 最早什么时候能再发一次。
    public func nextSlot(now: Date) -> Date {
        if let blockedUntil, now < blockedUntil { return blockedUntil }
        let live = active(now: now).sorted()
        guard live.count >= limit else { return now }
        return live[live.count - limit].addingTimeInterval(window)
    }

    private func active(now: Date) -> [Date] {
        stamps.filter { now.timeIntervalSince($0) < window }
    }

    /// Groq 的 429 文案里的「Please try again in 1m26.4s」→ 秒数。
    public static func retryAfter(in message: String) -> TimeInterval? {
        guard let range = message.range(of: #"try again in (?:(\d+)m)?(\d+(?:\.\d+)?)(ms|s)"#,
                                        options: .regularExpression) else { return nil }
        let match = String(message[range]).replacingOccurrences(of: "try again in ", with: "")
        var minutes = 0.0
        var rest = Substring(match)
        if let m = rest.firstIndex(of: "m"), rest[rest.index(after: m)...].first != "s",
           let value = Double(rest[..<m]) {
            minutes = value
            rest = rest[rest.index(after: m)...]
        }
        if rest.hasSuffix("ms"), let value = Double(rest.dropLast(2)) { return minutes * 60 + value / 1000 }
        if rest.hasSuffix("s"), let value = Double(rest.dropLast()) { return minutes * 60 + value }
        return nil
    }
}
