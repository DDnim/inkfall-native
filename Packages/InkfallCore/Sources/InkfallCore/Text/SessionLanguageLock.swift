import Foundation

/// 一次会话的语言锁定：**要两段判出同一种语言才锁**。
///
/// ## 为什么不是「第一段说了算」
///
/// Whisper 对短句的自动检测经常判错 —— 第一句往往又短又急（「那我们开始吧」
/// 这种），一旦被判成别的语言，整场会话就都跟着错，输出是一串音译垃圾。
/// 用第一段单独定生死，等于把整场押在最不可靠的那一次判断上。
///
/// 所以改成投票：谁先拿到 `requiredAgreement` 票谁锁定。
/// 韩 → 中 → 中 的序列会在第三段锁到中文，而不是被第一段的误判带走。
///
/// 迟迟凑不齐一致（每段都判成不同语言，通常意味着音频本身很糟）时，
/// 到 `maxVotes` 就按票数最多的锁下来，避免整场都在「自动检测」里飘。
public struct SessionLanguageLock: Sendable, Equatable {

    /// 锁定需要的一致票数。
    public static let requiredAgreement = 2
    /// 最多收集多少段的判断。到顶就按多数决收敛。
    public static let maxVotes = 5

    /// 已锁定的语言。`nil` 表示还在投票，这一段仍然交给模型自动检测。
    public private(set) var locked: TranscriptionLanguage?
    /// 按顺序记下的有效票，只用于诊断与多数决。
    public private(set) var votes: [TranscriptionLanguage] = []

    public init() {}

    /// 喂进一段的检测结果。
    ///
    /// - Parameters:
    ///   - detected: 这一段模型判出来的语言；`nil`（没判出来）直接忽略，不算票。
    ///   - policy: 用来过滤不该参与投票的结果（固定模式不锁；preferred 模式
    ///     只接受候选表里的语言 —— 一句噪声被判成越南语不该有投票权）。
    /// - Returns: 这一次调用是否**刚刚**完成锁定。
    @discardableResult
    public mutating func observe(_ detected: TranscriptionLanguage?,
                                 policy: TranscriptionLanguagePolicy) -> Bool {
        guard locked == nil else { return false }
        guard policy.shouldLock(detected: detected, locked: locked),
              let detected else { return false }

        votes.append(detected)

        // 谁先凑够一致票谁赢。
        let tally = votes.reduce(into: [TranscriptionLanguage: Int]()) { $0[$1, default: 0] += 1 }
        if tally[detected, default: 0] >= Self.requiredAgreement {
            locked = detected
            return true
        }

        // 收够上限还没有人达成一致：按多数决收敛，同票取**最近**的一票 ——
        // 越靠后的段通常越长，判得也越准。
        if votes.count >= Self.maxVotes {
            var best = votes[votes.count - 1]
            var bestCount = 0
            for language in votes.reversed() {
                let count = tally[language, default: 0]
                if count > bestCount {
                    best = language
                    bestCount = count
                }
            }
            locked = best
            return true
        }
        return false
    }

    /// 换一场会话。
    public mutating func reset() {
        locked = nil
        votes.removeAll()
    }
}
