import Foundation

/// 边听边插话（助手模式的长录音）里「一句话」的记账。纯状态机，网络和音频都在调用方。
///
/// 做法（2026-09-30 境）：
/// 1. 停顿 0.2 秒（`SilenceSegmenter` 的 `.pause`）就把**这句开头到现在**的音频转写一遍（发一张票）
/// 2. 问 Jev 说完了没有：说完了就收（在这张票的位置切音频，后面的留给下一句），交给纠错；
///    没说完就接着攒，下一次停顿再把**攒下来的全部**转写一遍
/// 3. 停顿到 1.5 秒（`.cut`）不管说没说完都收
///
/// 票会并发：前一张还在路上，说话人又停了一下，就再发一张（覆盖更多音频）。
/// 哪张先被判「说完了」就收哪张，同一句里剩下的票全部作废（它们的音频要么被收走了，要么包含被收走的部分）。
public struct LiveUtteranceTracker: Sendable {

    public enum Kind: Sendable, Equatable {
        /// 停顿 0.2 秒的试探：只转写到票的位置，说完了才收
        case pause
        /// 这句一定要收了（停顿 1.5 秒、停止录音、念纠正之前）
        case final
    }

    public struct Ticket: Sendable, Hashable {
        public let id: Int
        public let kind: Kind
        let generation: Int
        /// 发票时 `resume` 的累计次数：收这张票时用来判断它之后有没有人又说了话。
        let resumes: Int
    }

    public enum CutPlan: Sendable, Equatable {
        /// 这句里没有要转写的话（没说过，或只有语气词）：音频扔掉
        case nothing
        /// 最后那张票之后没人再说话，它的文字和 Jev 的回答直接用
        case reuse(Ticket, text: String, gate: InterjectionAPI.Gate)
        /// 最后那张票还在路上：等它回来，当最终的用（不再看说完了没有）
        case awaiting(Ticket)
        /// 整段重新转写（最后那张票之后又说了话 / 停顿时没发票 / 试探失败了）
        case fresh(Ticket)
    }

    public enum Next: Sendable, Equatable {
        /// 过时的票（这句已经收了）
        case ignore
        /// 转写出了有内容的话：去问 Jev
        case askJev
        /// 接着攒（没说完、只有语气词、试探失败）
        case wait
        /// 这句收了：去纠错。`final == false` 时调用方要在这张票的位置切音频
        case commit(final: Bool)
        /// 最终那次只有语气词 / 失败了：这句作废
        case discard
    }

    private enum State: Sendable, Equatable {
        case inFlight
        case transcribed(String)
        case judged(String, InterjectionAPI.Gate)
        case meaningless
        case failed
    }

    private var generation = 0
    private var nextID = 0
    private var resumes = 0
    /// 这句最近发出的那张票（1.5 秒时看它覆盖没覆盖全部的话）。
    private var last: (ticket: Ticket, state: State)?
    /// 最后那张票之后有没有没转写过的话。
    private var spokeSinceLast = false
    /// 已经收尾、一定要处理完的票（1.5 秒时在路上的、整段重新转写的）。
    private var finals: Set<Int> = []
    private var texts: [Int: String] = [:]

    public init() {}

    /// 停顿 0.2 秒，调用方要转写 → 发一张试探票。
    public mutating func pause() -> Ticket {
        let ticket = issue(.pause)
        last = (ticket, .inFlight)
        spokeSinceLast = false
        return ticket
    }

    /// 停顿 0.2 秒但调用方没转写（预算不够、音频太短）。
    public mutating func skipPause() {
        spokeSinceLast = true
    }

    /// 停顿之后又开口了。
    public mutating func resume() {
        resumes += 1
        spokeSinceLast = true
    }

    /// 停顿 1.5 秒（或停止录音、念纠正之前）：这句不管说没说完都收。调用方随后把音频全部取走。
    public mutating func cut() -> CutPlan {
        defer { closeUtterance() }
        guard let last, !spokeSinceLast else {
            guard spokeSinceLast else { return .nothing }
            let ticket = issue(.final)
            finals.insert(ticket.id)
            return .fresh(ticket)
        }
        switch last.state {
        case .inFlight, .transcribed:
            finals.insert(last.ticket.id)
            return .awaiting(last.ticket)
        case .judged(let text, let gate):
            return .reuse(last.ticket, text: text, gate: gate)
        case .meaningless:
            return .nothing
        case .failed:
            let ticket = issue(.final)
            finals.insert(ticket.id)
            return .fresh(ticket)
        }
    }

    /// 这张票已经收尾、一定要处理完（1.5 秒时在路上的、整段重新转写的）。
    public func isFinal(_ ticket: Ticket) -> Bool {
        finals.contains(ticket.id)
    }

    public mutating func transcribed(_ ticket: Ticket, text: String) -> Next {
        if finals.contains(ticket.id) {
            guard !InterjectionAPI.isMeaningless(text) else {
                finals.remove(ticket.id)
                return .discard
            }
            texts[ticket.id] = text
            return .askJev
        }
        guard ticket.generation == generation else { return .ignore }
        let meaningless = InterjectionAPI.isMeaningless(text)
        if last?.ticket == ticket { last?.state = meaningless ? .meaningless : .transcribed(text) }
        guard !meaningless else { return .wait }
        texts[ticket.id] = text
        return .askJev
    }

    public mutating func judged(_ ticket: Ticket, gate: InterjectionAPI.Gate) -> Next {
        if finals.remove(ticket.id) != nil {
            texts[ticket.id] = nil
            return .commit(final: true)
        }
        guard ticket.generation == generation else { return .ignore }
        if gate.isCompleteLive {
            let spokeAfter = resumes > ticket.resumes
            closeUtterance()
            spokeSinceLast = spokeAfter
            return .commit(final: false)
        }
        if last?.ticket == ticket, let text = texts[ticket.id] { last?.state = .judged(text, gate) }
        return .wait
    }

    public mutating func failed(_ ticket: Ticket) -> Next {
        if finals.remove(ticket.id) != nil { return .discard }
        guard ticket.generation == generation else { return .ignore }
        if last?.ticket == ticket { last?.state = .failed }
        return .wait
    }

    /// 念纠正期间录到的音频整段扔掉：在路上的试探票全部作废（已经收尾的照常处理）。
    public mutating func discardAll() {
        closeUtterance()
    }

    private mutating func issue(_ kind: Kind) -> Ticket {
        nextID += 1
        return Ticket(id: nextID, kind: kind, generation: generation, resumes: resumes)
    }

    private mutating func closeUtterance() {
        generation += 1
        last = nil
        spokeSinceLast = false
        texts = texts.filter { finals.contains($0.key) }
    }
}
