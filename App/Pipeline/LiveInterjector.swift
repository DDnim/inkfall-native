import Foundation
import InkfallCore

/// 录音那一头：真麦克风（`RecorderLiveSource`）或自测用的 wav（`FileLiveSource`）。
@MainActor
protocol LiveAudioSource: AnyObject {
    var level: Float { get }
    /// 这一段（上次取走以来）的音频复制一份 + 当前位置
    func peek() -> (audio: RecordedAudio, mark: AudioRecorder.Mark)?
    /// 在位置上切：之前的扔掉（已经转写过），之后的留给下一句
    @discardableResult func cut(upTo mark: AudioRecorder.Mark) -> Bool
    /// 全部取走
    func takeAll() -> RecordedAudio?
    /// 这一段最近 ≤ 8 秒的原始音频（不压静音），16 kHz 单声道：给 Smart Turn 听
    func turnWindow() -> [Float]?
}

@MainActor
final class RecorderLiveSource: LiveAudioSource {
    private let recorder: AudioRecorder
    init(_ recorder: AudioRecorder) { self.recorder = recorder }
    var level: Float { recorder.level }
    func peek() -> (audio: RecordedAudio, mark: AudioRecorder.Mark)? { recorder.peekSegment() }
    func cut(upTo mark: AudioRecorder.Mark) -> Bool { recorder.flushSegment(upTo: mark) }
    func takeAll() -> RecordedAudio? { try? recorder.flushSegment(retainingTailMs: 0) }
    func turnWindow() -> [Float]? {
        recorder.recentPCM(seconds: 8.1).map { SmartTurn.window(pcm: $0.pcm, sampleRate: $0.rate, channels: $0.channels) }
    }
}

/// 边听边插话（助手模式的长录音，2026-09-30 境）。
///
/// 停顿 0.2 秒先让本机的 Smart Turn 听一下语调（约 3 ms）：判没说完就接着听，静音每长 0.2 秒再问；
/// 判说完了才把这句开头到现在的音频送去转写（Groq Whisper），Jev 也判说完了就收下这句交给纠错
/// （两边都说完才算完）；没说完就接着攒，下次停顿再整段转写，停顿 1.5 秒硬收。记账在 InkfallCore 的 `LiveUtteranceTracker`，
/// 这里只管发请求、切音频、打日志。收下的句子交给 `onFinished`（纠错 / 回答由调用方做）。
@MainActor
final class LiveInterjector {

    static let pauseSeconds = 0.2
    static let cutSeconds = 1.5
    /// Groq 免费档 whisper-large-v3-turbo 每分钟 20 次。升级 Dev 档之后可以用
    /// `defaults write <bundle> inkfall.liveWhisperRPM 300` 放开。
    static var whisperRPM: Int {
        let stored = UserDefaults.standard.integer(forKey: "inkfall.liveWhisperRPM")
        return stored > 0 ? stored : 20
    }
    /// 停顿时的试探至少给「这句收尾」留这么多次。
    static let finalReserve = 4
    /// 收尾那次没额度时最多等这么久，再久话题就过去了。
    static let maxBudgetWait: TimeInterval = 4
    /// 一句攒到这么长（静音压缩后）还没被判说完，下一次停顿就硬收 —— 别让它滚雪球。
    static let maxUtteranceMs: UInt64 = 12_000
    /// 停顿时先问 Smart Turn。关掉（`defaults write <bundle> inkfall.liveSmartTurn -bool NO`）就回到只靠 Jev。
    static var useSmartTurn: Bool {
        UserDefaults.standard.object(forKey: "inkfall.liveSmartTurn") as? Bool ?? true
    }

    /// 抢话（见 InkfallCore `BargeIn`）。关掉：`defaults write <bundle> inkfall.liveBargeIn -bool NO`（回到等说完再插）。
    static var useBargeIn: Bool {
        UserDefaults.standard.object(forKey: "inkfall.liveBargeIn") as? Bool ?? true
    }
    /// `--live-sim --no-barge-in` 用来对比。
    var bargeInEnabled = LiveInterjector.useBargeIn

    struct Finished {
        let text: String
        let gate: InterjectionAPI.Gate
        /// `pause`：停顿 0.2 秒时 Jev 判说完了；`final`：硬收（1.5 秒 / 停止 / 念之前）
        let kind: LiveUtteranceTracker.Kind
        /// 估计的「说完那一刻」（停顿开始），算延迟用
        let spokeUntil: CFAbsoluteTime
        let durationMs: UInt64
    }

    typealias Transcribe = @MainActor (RecordedAudio) async throws -> String

    var onFinished: (Finished) -> Void = { _ in }
    /// 抢话：这句还没说完，但已经像在说事实（不收下这句，只拿去核对）。
    var onUnfinishedClaim: (Finished) -> Void = { _ in }
    /// 结构化的过程记录：App 里写日志，`--live-sim` 里写 JSONL。
    var trace: (String, [String: Any]) -> Void = { _, _ in }

    private let probe: InterjectionProbe
    private let transcribe: Transcribe
    private var source: LiveAudioSource?
    /// 两次停顿之间至少又说了这么久才再转写一遍：「嗯」「水到……」这种短的不单独花一次
    /// Groq 的额度（每分钟 20 次），攒进下一次。有 Smart Turn 先筛就放宽到 0.3 秒 —— 否则「什么事」这种
    /// 短的回话会和下一个人的话并成一段（「什么事？你知道吗？苹果其实是一种蔬菜」被 Qwen 当成提问放过了）。
    static let pauseMinSpeechSeconds = 0.6
    static let pauseMinSpeechSecondsWithTurn = 0.3
    /// Smart Turn 一直判没说完、静音到这么久还没人开口：照旧转写，交给 Jev 判。它把说完的句子判成没说完时
    /// （Qwen3-TTS 的女声「是啊，夏天就是这样」0.03），对方一接话两个人的话就并成一段，纠正晚 2 秒以上。
    static var turnGiveUpSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: "inkfall.liveTurnGiveUp")
        return stored > 0 ? stored : 0.6
    }
    private(set) var segmenter = SilenceSegmenter()
    /// `--live-sim --turn-give-up <秒>` 用来对比（很大 = 只信 Smart Turn）。
    var turnGiveUp = LiveInterjector.turnGiveUpSeconds
    private var tracker = LiveUtteranceTracker()
    private var watch = TurnEndWatch()
    private let turnModel = SmartTurnModel.shared
    /// `--live-sim --no-smart-turn` 用来对比。
    var smartTurnEnabled = LiveInterjector.useSmartTurn
    private var budget = RequestBudget(limit: LiveInterjector.whisperRPM)
    private var marks: [Int: AudioRecorder.Mark] = [:]
    private var spokeUntil: [Int: CFAbsoluteTime] = [:]
    private var durations: [Int: UInt64] = [:]
    /// `cut(reason:heard:)` 等着的转写结果。
    private var listeners: [Int: @MainActor (String?) -> Void] = [:]
    /// 最近几次开口的时刻（看纠正准备好时是不是有人紧接着在说）。
    private var speechStarts: [CFAbsoluteTime] = []
    private var wasSpeaking = false
    /// 在路上的请求（自测等它们归零再退出）。
    private(set) var inFlight = 0

    init(probe: InterjectionProbe, transcribe: @escaping Transcribe) {
        self.probe = probe
        self.transcribe = transcribe
    }

    var isActive: Bool { source != nil }

    func start(source: LiveAudioSource) {
        self.source = source
        segmenter = SilenceSegmenter(config: .init(
            silenceCutSeconds: Self.cutSeconds, pauseSeconds: Self.pauseSeconds,
            pauseMinSpeechSeconds: smartTurnEnabled ? Self.pauseMinSpeechSecondsWithTurn : Self.pauseMinSpeechSeconds))
        tracker = LiveUtteranceTracker()
        watch = TurnEndWatch()
        if smartTurnEnabled { turnModel.prepare() }
        marks = [:]
        spokeUntil = [:]
        durations = [:]
        listeners = [:]
        speechStarts = []
        wasSpeaking = false
        probe.prewarm()
        trace("start", ["rpm": Self.whisperRPM, "give_up": turnGiveUp, "barge_in": bargeInEnabled,
                        "smart_turn": smartTurnEnabled ? (turnModel.isReady ? "ready" : "loading") : "off"])
    }

    /// 30 Hz 调一次（念纠正的期间调用方不调）。
    func tick(level: Float, delta: Double) {
        guard source != nil else { return }
        let event = segmenter.step(level: level, delta: delta)
        if segmenter.isSpeaking, !wasSpeaking {
            // 连续超过阈值 `speechAttackSeconds` 才算开口：真正开口的时刻要往回扣
            speechStarts.append(CFAbsoluteTimeGetCurrent() - segmenter.config.speechAttackSeconds)
            if speechStarts.count > 8 { speechStarts.removeFirst() }
        }
        wasSpeaking = segmenter.isSpeaking
        switch event {
        case .pause?:
            watch.paused(silence: segmenter.silenceSeconds)
            considerTurnEnd()
        case .resume?:
            watch.stop()
            tracker.resume()
            trace("resume", [:])
        case .cut?:
            cut(reason: "pause-1.5s")
        case nil:
            considerTurnEnd()
        }
    }

    /// 停顿里到点了就问 Smart Turn：判没说完接着听（不转写，过 0.2 秒再问）；判说完了（或模型还没好）才转写。
    private func considerTurnEnd() {
        let silence = segmenter.silenceSeconds
        guard watch.due(silence: silence), let source else { return }
        if smartTurnEnabled, turnModel.isReady, let samples = source.turnWindow(),
           let probability = turnModel.probability(samples) {
            let done = probability > SmartTurn.threshold
            let givingUp = !done && silence >= turnGiveUp
            trace("turn", ["p": (Double(probability) * 100).rounded() / 100, "silence": (silence * 100).rounded() / 100,
                           "done": done, "give_up": givingUp])
            guard done || givingUp else {
                // 抢话：没说完也转写，好在半句里听到说错的事实就插嘴 —— 但给说完的句子多留额度
                if bargeInEnabled, budget.allows(reserve: Self.finalReserve + BargeIn.unfinishedReserve, now: Date()) {
                    watch.stop()
                    speculate(silence: silence)
                    return
                }
                if bargeInEnabled { trace("pause-skip", ["why": "budget-unfinished", "remaining": budget.remaining(now: Date())]) }
                tracker.skipPause()
                return
            }
        }
        watch.stop()
        speculate(silence: silence)
    }

    /// 这句不管说没说完都收（停顿 1.5 秒、180 秒硬上限、念纠正之前）。
    /// - `heard`: 这句转写出来的字（没有要转写的 / 失败了是 nil）。先听接着说的再决定插不插时用。
    func cut(reason: String, heard: (@MainActor (String?) -> Void)? = nil) {
        guard let source else { heard?(nil); return }
        watch.stop()
        close(plan: tracker.cut(), audio: { source.takeAll() }, reason: reason,
              spokeUntil: CFAbsoluteTimeGetCurrent() - (reason == "pause-1.5s" ? Self.cutSeconds : 0), heard: heard)
    }

    /// 停顿开始（`after`）之后很快就有人接着说（见 `InterjectionPolicy.continuesQuickly`）。
    func continuesQuickly(after pauseStartedAt: CFAbsoluteTime) -> Bool {
        InterjectionPolicy.continuesQuickly(pauseStartedAt: pauseStartedAt, speechStarts: speechStarts)
    }

    /// 停止录音：最后那截由调用方从录音器取出来。
    func stop(finalAudio: RecordedAudio?) {
        guard source != nil else { return }
        close(plan: tracker.cut(), audio: { finalAudio }, reason: "stop", spokeUntil: CFAbsoluteTimeGetCurrent())
        source = nil
    }

    /// 念纠正的期间录到的整段扔掉（那是 AI 的声音），之后从头来。
    func discardVoice() {
        guard let source else { return }
        let dropped = source.takeAll()?.durationMs ?? 0
        tracker.discardAll()
        segmenter.resetSegment()
        watch.stop()
        trace("discard-voice", ["ms": dropped])
    }

    // MARK: - 试探与收尾

    private func speculate(silence: Double) {
        guard let source else { return }
        let now = Date()
        guard let (audio, mark) = source.peek(),
              RecordingSubmissionPolicy.default.verdict(for: audio) == .submit else {
            tracker.skipPause()
            trace("pause-skip", ["why": "short-or-silent"])
            return
        }
        guard audio.durationMs < Self.maxUtteranceMs else {
            trace("pause-too-long", ["ms": audio.durationMs])
            cut(reason: "too-long")
            return
        }
        guard budget.allows(reserve: Self.finalReserve, now: now) else {
            tracker.skipPause()
            trace("pause-skip", ["why": "budget", "remaining": budget.remaining(now: now)])
            return
        }
        let ticket = tracker.pause()
        marks[ticket.id] = mark
        spokeUntil[ticket.id] = CFAbsoluteTimeGetCurrent() - silence
        durations[ticket.id] = audio.durationMs
        trace("pause", ["ticket": ticket.id, "ms": audio.durationMs, "silence": (silence * 100).rounded() / 100])
        run(ticket, audio: audio)
    }

    private func close(plan: LiveUtteranceTracker.CutPlan, audio: () -> RecordedAudio?,
                       reason: String, spokeUntil until: CFAbsoluteTime, heard: (@MainActor (String?) -> Void)? = nil) {
        switch plan {
        case .nothing:
            let dropped = audio()?.durationMs ?? 0
            trace("cut", ["reason": reason, "plan": "nothing", "ms": dropped])
            heard?(nil)
        case .reuse(let ticket, let text, let gate):
            _ = audio()
            trace("cut", ["reason": reason, "plan": "reuse", "ticket": ticket.id, "text": text])
            heard?(text)
            finish(ticket, text: text, gate: gate)
        case .awaiting(let ticket):
            _ = audio()
            trace("cut", ["reason": reason, "plan": "await", "ticket": ticket.id])
            if let heard { listeners[ticket.id] = heard }
        case .fresh(let ticket):
            guard let recorded = audio(), RecordingSubmissionPolicy.default.verdict(for: recorded) == .submit else {
                _ = tracker.failed(ticket)
                trace("cut", ["reason": reason, "plan": "fresh-dropped", "ticket": ticket.id])
                heard?(nil)
                return
            }
            if let heard { listeners[ticket.id] = heard }
            spokeUntil[ticket.id] = until
            durations[ticket.id] = recorded.durationMs
            trace("cut", ["reason": reason, "plan": "fresh", "ticket": ticket.id, "ms": recorded.durationMs])
            run(ticket, audio: recorded)
        }
    }

    /// 转写 → 问 Jev → 按记账的结果收 / 等 / 扔。
    private func run(_ ticket: LiveUtteranceTracker.Ticket, audio: RecordedAudio) {
        inFlight += 1
        Task { @MainActor in
            defer { inFlight -= 1 }
            let transcript = await transcribeWithinBudget(ticket, audio: audio)
            listeners.removeValue(forKey: ticket.id)?(transcript)
            guard let heard = transcript else {
                if tracker.failed(ticket) == .discard { trace("discard", ["ticket": ticket.id, "why": "transcribe-failed"]) }
                return
            }
            let text = InterjectionAPI.dropTrailingComma(heard)
            switch tracker.transcribed(ticket, text: text) {
            case .askJev: break
            case .discard:
                trace("discard", ["ticket": ticket.id, "why": "meaningless", "text": text])
                return
            case .ignore:
                trace("stale", ["ticket": ticket.id, "text": text])
                return
            default:
                trace("wait", ["ticket": ticket.id, "why": "meaningless", "text": text])
                return
            }
            let started = CFAbsoluteTimeGetCurrent()
            var gate = await probe.askGate(segment: text, live: true)
            if gate == nil, tracker.isFinal(ticket) {
                // 收尾这次 Jev 没回来（超时 0.8 秒）：不丢这句，不看门槛直接交给核对（Qwen 自己会判是不是断言）
                trace("jev-failed", ["ticket": ticket.id, "fallback": "check"])
                gate = InterjectionAPI.Gate(complete: 1, claim: 1)
            }
            guard let gate else {
                if tracker.failed(ticket) == .discard { trace("discard", ["ticket": ticket.id, "why": "jev-failed"]) }
                return
            }
            let jevMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            let next = tracker.judged(ticket, gate: gate)
            trace("jev", ["ticket": ticket.id, "text": text, "complete": gate.complete, "claim": gate.claim,
                          "ms": jevMs, "next": "\(next)"])
            switch next {
            case .commit(let final):
                if !final, let mark = marks[ticket.id], let source {
                    if !source.cut(upTo: mark) { trace("cut-mark-lost", ["ticket": ticket.id]) }
                }
                finish(ticket, text: text, gate: gate)
            case .wait where bargeInEnabled && BargeIn.checksUnfinished(gate):
                trace("barge-in", ["ticket": ticket.id, "text": text, "claim": gate.claim])
                onUnfinishedClaim(Finished(text: text, gate: gate, kind: ticket.kind,
                                           spokeUntil: spokeUntil[ticket.id] ?? CFAbsoluteTimeGetCurrent(),
                                           durationMs: durations[ticket.id] ?? 0))
            default:
                break
            }
        }
    }

    private func transcribeWithinBudget(_ ticket: LiveUtteranceTracker.Ticket, audio: RecordedAudio) async -> String? {
        for attempt in 0..<2 {
            if ticket.kind == .final {
                let wait = budget.nextSlot(now: Date()).timeIntervalSinceNow
                if wait > Self.maxBudgetWait {
                    trace("budget-exhausted", ["ticket": ticket.id, "wait": wait])
                    return nil
                }
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            budget.spend(now: Date())
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let text = try await transcribe(audio)
                trace("whisper", ["ticket": ticket.id, "kind": ticket.kind == .pause ? "pause" : "final",
                                  "ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000), "text": text])
                return text
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if message.contains("429") {
                    let retry = RequestBudget.retryAfter(in: message) ?? 5
                    budget.block(until: Date().addingTimeInterval(retry))
                    trace("whisper-429", ["ticket": ticket.id, "retry": retry])
                    if ticket.kind == .final, attempt == 0 { continue }
                } else {
                    trace("whisper-failed", ["ticket": ticket.id, "error": String(message.prefix(160))])
                }
                return nil
            }
        }
        return nil
    }

    private func finish(_ ticket: LiveUtteranceTracker.Ticket, text: String, gate: InterjectionAPI.Gate) {
        let finished = Finished(text: text, gate: gate, kind: ticket.kind,
                                spokeUntil: spokeUntil[ticket.id] ?? CFAbsoluteTimeGetCurrent(),
                                durationMs: durations[ticket.id] ?? 0)
        marks[ticket.id] = nil
        spokeUntil[ticket.id] = nil
        durations[ticket.id] = nil
        trace("commit", ["ticket": ticket.id, "kind": ticket.kind == .pause ? "pause" : "final", "text": text,
                         "since_speech_ms": Int((CFAbsoluteTimeGetCurrent() - finished.spokeUntil) * 1000)])
        onFinished(finished)
    }
}
