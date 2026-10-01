import XCTest
@testable import InkfallCore

// 边听边插话（助手模式的长录音）不碰网络的那一半：
// 停顿 0.2 秒的「先转写一遍」事件、一句话怎么攒 / 什么时候收、Groq 免费档的请求预算。
// 发请求那一层在 App（`LiveInterjector`），靠 `--live-sim <wav>` 验证。

final class SegmenterPauseEventTests: XCTestCase {

    private let frame = 1.0 / 30      // 与刘海计时同一个 30 Hz
    private let speech: Float = 0.05
    private let silence: Float = 0.0

    private func live() -> SilenceSegmenter {
        SilenceSegmenter(config: .init(silenceCutSeconds: 1.5, pauseSeconds: 0.2))
    }

    /// 恒定电平喂 `seconds` 秒，收集事件。
    private func feed(_ seg: inout SilenceSegmenter, _ level: Float, _ seconds: Double) -> [SilenceSegmenter.Event] {
        var events: [SilenceSegmenter.Event] = []
        for _ in 0..<Int((seconds / frame).rounded()) {
            if let event = seg.step(level: level, delta: frame) { events.append(event) }
        }
        return events
    }

    func testShortPauseFiresOnceThenCutAtLongPause() {
        var seg = live()
        _ = seg.step(level: silence, delta: frame)
        XCTAssertEqual(feed(&seg, speech, 1.0), [])
        XCTAssertEqual(feed(&seg, silence, 0.3), [.pause])
        XCTAssertEqual(feed(&seg, silence, 1.4), [.cut])      // 同一段静音里，到 1.5 秒切
        XCTAssertEqual(feed(&seg, silence, 5), [])
    }

    func testSpeechAfterPauseResumesAndCanPauseAgain() {
        var seg = live()
        _ = seg.step(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        XCTAssertEqual(feed(&seg, silence, 0.3), [.pause])
        XCTAssertEqual(feed(&seg, speech, 0.5), [.resume])
        XCTAssertEqual(feed(&seg, silence, 0.3), [.pause])
    }

    /// 停顿之间只冒出一点点声音（一声「嗯」、一下杂音）不值得再转写一遍，但算说过话。
    func testTinySpeechBetweenPausesDoesNotPauseAgain() {
        var seg = live()
        _ = seg.step(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        XCTAssertEqual(feed(&seg, silence, 0.3), [.pause])
        XCTAssertEqual(feed(&seg, speech, 0.2), [.resume])
        XCTAssertEqual(feed(&seg, silence, 1.6), [.cut])
    }

    func testPauseNeedsArmedSegment() {
        var seg = live()
        _ = seg.step(level: silence, delta: frame)
        XCTAssertEqual(feed(&seg, speech, 0.2), [])           // < minSpeechSeconds，没上膛
        XCTAssertEqual(feed(&seg, silence, 3), [])
    }

    /// 没配 `pauseSeconds`（输入模式、移动端）：行为和原来一模一样，只有切段。
    func testDefaultConfigNeverPauses() {
        var seg = SilenceSegmenter()
        _ = seg.step(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        XCTAssertEqual(feed(&seg, silence, 0.5), [])
        XCTAssertEqual(feed(&seg, speech, 0.5), [])
        XCTAssertEqual(feed(&seg, silence, 1.5), [.cut])
    }
}

final class LiveUtteranceTrackerTests: XCTestCase {

    private let complete = InterjectionAPI.Gate(complete: 0.8, claim: 0.9)
    private let incomplete = InterjectionAPI.Gate(complete: 0.1, claim: 0.5)

    /// 边听边插话的门槛比 1.3 秒切段的高：「对了，日本的首都」这种导语 Jev 给 0.3–0.45。
    func testLiveThresholdIsStricter() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        _ = t.transcribed(a, text: "对了，日本的首都")
        XCTAssertEqual(t.judged(a, gate: .init(complete: 0.45, claim: 0.8)), .wait)
    }

    /// 「苹果是蔬菜」一口气说完：停顿 0.2 秒转写 → Jev 说完了 → 收（在这张票的位置切音频）。
    func testCompleteAtFirstPauseCommits() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertEqual(t.transcribed(a, text: "苹果是一种蔬菜"), .askJev)
        XCTAssertEqual(t.judged(a, gate: complete), .commit(final: false))
        XCTAssertEqual(t.cut(), .nothing, "收完之后没人再说话，1.5 秒切下来的只有静音")
    }

    /// 「苹果是……蔬菜」：第一张票没说完就接着攒，第二张票（从句首到现在）说完了才收。
    func testIncompleteKeepsAccumulating() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertEqual(t.transcribed(a, text: "苹果是"), .askJev)
        XCTAssertEqual(t.judged(a, gate: incomplete), .wait)
        t.resume()
        let b = t.pause()
        XCTAssertEqual(t.transcribed(b, text: "苹果是蔬菜"), .askJev)
        XCTAssertEqual(t.judged(b, gate: complete), .commit(final: false))
    }

    /// 一直没说完：停顿到 1.5 秒硬收。最后那张票之后没再说话 → 直接用它的文字和 Jev 的回答，不再转写。
    func testCutReusesLastTranscriptWhenNothingWasSaidAfterIt() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        _ = t.transcribed(a, text: "所以我觉得")
        _ = t.judged(a, gate: incomplete)
        XCTAssertEqual(t.cut(), .reuse(a, text: "所以我觉得", gate: incomplete))
    }

    /// 最后那张票还在路上就到了 1.5 秒：等它回来，不管 Jev 怎么说都当说完了。
    func testCutPromotesTicketStillInFlight() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertEqual(t.cut(), .awaiting(a))
        XCTAssertEqual(t.transcribed(a, text: "我们明天"), .askJev)
        XCTAssertEqual(t.judged(a, gate: incomplete), .commit(final: true))
    }

    /// 最后那张票之后又说了话（或者停顿时没转写）：整段重新转写，当最终的。
    func testCutAfterNewSpeechTranscribesAfresh() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        _ = t.transcribed(a, text: "我跟你说")
        _ = t.judged(a, gate: incomplete)
        t.resume()
        guard case .fresh(let f) = t.cut() else { return XCTFail("应该整段重新转写") }
        XCTAssertEqual(f.kind, .final)
        XCTAssertEqual(t.transcribed(f, text: "我跟你说日本的首都是大阪"), .askJev)
        XCTAssertEqual(t.judged(f, gate: incomplete), .commit(final: true))
        XCTAssertEqual(t.judged(a, gate: complete), .ignore, "旧的票已经过时")
    }

    func testCutWithoutAnyTicketButSpeechIsFresh() {
        var t = LiveUtteranceTracker()
        t.resume()
        guard case .fresh = t.cut() else { return XCTFail() }
        var silent = LiveUtteranceTracker()
        XCTAssertEqual(silent.cut(), .nothing, "没说过话")
    }

    /// 前一张票收了，后一张（包含前一张的音频）就过时了；收之后又说了话，1.5 秒切的是新的一句。
    func testCommitMakesLaterTicketsStale() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        t.resume()
        let b = t.pause()
        _ = t.transcribed(a, text: "今天天气不错")
        XCTAssertEqual(t.judged(a, gate: complete), .commit(final: false))
        XCTAssertEqual(t.transcribed(b, text: "今天天气不错我们去"), .ignore)
        guard case .fresh = t.cut() else { return XCTFail("a 之后说过话，剩下的要重新转写") }
    }

    func testLaterTicketCommitMakesEarlierStale() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        t.resume()
        let b = t.pause()
        _ = t.transcribed(b, text: "苹果是蔬菜")
        XCTAssertEqual(t.judged(b, gate: complete), .commit(final: false))
        XCTAssertEqual(t.transcribed(a, text: "苹果是"), .ignore)
    }

    /// 旧票的结果晚回来，不能覆盖新票（1.5 秒时要用的是覆盖全部语音的那张）。
    func testOlderResultDoesNotReplaceTheLatestForReuse() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        t.resume()
        let b = t.pause()
        _ = t.transcribed(b, text: "我觉得这个方案")
        _ = t.judged(b, gate: incomplete)
        _ = t.transcribed(a, text: "我觉得")
        _ = t.judged(a, gate: incomplete)
        XCTAssertEqual(t.cut(), .reuse(b, text: "我觉得这个方案", gate: incomplete))
    }

    /// 无意义的（语气词、应答）：停顿时不问 Jev 接着等；最终的直接扔掉。
    func testFillerIsNotAskedAndFinalFillerIsDiscarded() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertEqual(t.transcribed(a, text: "嗯。"), .wait)
        XCTAssertEqual(t.cut(), .nothing, "整句只有语气词：扔掉")
        t.resume()
        guard case .fresh(let f) = t.cut() else { return XCTFail() }
        XCTAssertEqual(t.transcribed(f, text: "对对对"), .discard)
    }

    /// 停顿时没发票（预算不够、音频太短）：那段话没人转写过，1.5 秒时要整段转写。
    func testSkippedPauseStillCountsAsSpeech() {
        var t = LiveUtteranceTracker()
        t.skipPause()
        guard case .fresh = t.cut() else { return XCTFail() }
    }

    func testFailuresOnlyMatterForFinals() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertEqual(t.failed(a), .wait)
        guard case .fresh(let f) = t.cut() else { return XCTFail("试探失败了，最终那次要重来") }
        XCTAssertEqual(t.failed(f), .discard)
    }

    /// 念纠正的期间录到的整段扔掉：在路上的票全部作废，之后从头来。
    func testDiscardAllInvalidatesEverything() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        t.discardAll()
        XCTAssertEqual(t.transcribed(a, text: "苹果是蔬菜"), .ignore)
        XCTAssertEqual(t.cut(), .nothing)
    }
}

final class LiveTextTests: XCTestCase {

    func testMeaningless() {
        for text in ["", " ", "。", "嗯", "嗯嗯。", "啊？", "对对对", "好的", "哈哈哈", "えーと", "うん", "Um.", "OK"] {
            XCTAssertTrue(InterjectionAPI.isMeaningless(text), text)
        }
        for text in ["苹果是蔬菜", "对了，苹果是蔬菜", "好的，明天见", "水", "Yes, water boils at 50"] {
            XCTAssertFalse(InterjectionAPI.isMeaningless(text), text)
        }
    }

    /// 长录音边听边判时 Jev 问的是「停了 0.2 秒」而不是 1.3 秒。
    func testLiveGateAsksTheShortPauseQuestion() throws {
        let data = try XCTUnwrap(InterjectionAPI.gateBody(previous: [], segment: "苹果是", live: true))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try XCTUnwrap(root["questions"] as? [String: [String: String]])
        XCTAssertEqual(questions["complete"]?["instructions"], InterjectionAPI.liveCompleteQuestion)
        XCTAssertEqual(questions["claim"]?["instructions"], InterjectionAPI.claimQuestion)
    }
}

final class RequestBudgetTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testSlidingWindow() {
        var budget = RequestBudget(limit: 3, window: 60)
        XCTAssertEqual(budget.remaining(now: t0), 3)
        budget.spend(now: t0)
        budget.spend(now: t0.addingTimeInterval(10))
        XCTAssertEqual(budget.remaining(now: t0.addingTimeInterval(20)), 1)
        XCTAssertTrue(budget.allows(reserve: 0, now: t0.addingTimeInterval(20)))
        XCTAssertFalse(budget.allows(reserve: 1, now: t0.addingTimeInterval(20)), "停顿时的试探要给最终那次留余量")
        budget.spend(now: t0.addingTimeInterval(20))
        XCTAssertFalse(budget.allows(reserve: 0, now: t0.addingTimeInterval(30)))
        XCTAssertEqual(budget.nextSlot(now: t0.addingTimeInterval(30)), t0.addingTimeInterval(60))
        XCTAssertEqual(budget.remaining(now: t0.addingTimeInterval(60.5)), 1)
    }

    /// 服务端说 429 了：不管自己怎么算，等它说的时间。
    func testBlockedByServer() {
        var budget = RequestBudget(limit: 20, window: 60)
        budget.block(until: t0.addingTimeInterval(3))
        XCTAssertEqual(budget.remaining(now: t0), 0)
        XCTAssertEqual(budget.nextSlot(now: t0), t0.addingTimeInterval(3))
        XCTAssertEqual(budget.remaining(now: t0.addingTimeInterval(3.1)), 20)
    }

    func testRetryAfterFromGroqMessage() {
        XCTAssertEqual(RequestBudget.retryAfter(in: "Rate limit reached ... Please try again in 3s. Need more tokens?"), 3)
        XCTAssertEqual(RequestBudget.retryAfter(in: "Please try again in 37.74s."), 37.74)
        XCTAssertEqual(RequestBudget.retryAfter(in: "Please try again in 1m26.4s."), 86.4)
        XCTAssertNil(RequestBudget.retryAfter(in: "something else"))
    }
}

final class OutputTokenCapTests: XCTestCase {

    /// Groq 免费档按「预计输出 token」卡每分钟上限（qwen3.8-27b 1000 OTPM）：
    /// 不写 max_output_tokens，它按模型上限估，一次请求就超，直接 429。
    func testMaxOutputTokens() throws {
        let data = try XCTUnwrap(TextGenerationAPI.body(provider: .groq, model: "qwen/qwen3.8-27b",
                                                        instructions: "a", input: "b", maxOutputTokens: 160))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 160)
        let plain = try XCTUnwrap(TextGenerationAPI.body(provider: .groq, model: "qwen/qwen3.8-27b",
                                                         instructions: "a", input: "b"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["max_output_tokens"])
    }

    /// 核对要稳：Groq Qwen 默认温度下「地球是太阳系里最大的行星」三次里有一次判成「正确」，温度 0 三次一样（2026-10-01）。
    /// OpenAI 不设（推理模型不收 temperature，会 400）。
    func testCheckIsDeterministicWhereSupported() throws {
        XCTAssertEqual(InterjectionAPI.checkTemperature(for: .groq), 0)
        XCTAssertNil(InterjectionAPI.checkTemperature(for: .openai))
        let data = try XCTUnwrap(TextGenerationAPI.body(provider: .groq, model: "qwen/qwen3.8-27b",
                                                        instructions: "a", input: "b", temperature: 0))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["temperature"] as? Double, 0)
        let gemini = try XCTUnwrap(TextGenerationAPI.body(provider: .gemini, model: "m", instructions: "a", input: "b",
                                                          temperature: 0))
        let config = try XCTUnwrap((JSONSerialization.jsonObject(with: gemini) as? [String: Any])?["generationConfig"]
                                   as? [String: Any])
        XCTAssertEqual(config["temperature"] as? Double, 0)
    }
}

final class SmartTurnInputTests: XCTestCase {

    private func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBytes { Data($0) } }

    func testSixteenKilohertzMonoPassesThrough() {
        let window = SmartTurn.window(pcm: pcm([0, 16384, -16384, 32767]), sampleRate: 16_000, channels: 1)
        XCTAssertEqual(window, [0, 0.5, -0.5, Float(32767) / 32768])
    }

    /// 真麦克风多半是 48k、可能双声道：混成单声道、三个一平均。
    func testFortyEightKilohertzStereoIsMixedAndDecimated() {
        var interleaved: [Int16] = []
        for value: Int16 in [300, 600, 900, 1200, 1500, 1800] { interleaved += [value, value + 100] }
        let window = SmartTurn.window(pcm: pcm(interleaved), sampleRate: 48_000, channels: 2)
        XCTAssertEqual(window.count, 2)
        // 最后一个输出对齐最后一个输入：(1250 + 1550 + 1850) / 3
        XCTAssertEqual(window[1], 1550 / 32768, accuracy: 1e-6)
        XCTAssertEqual(window[0], 650 / 32768, accuracy: 1e-6)   // (350 + 650 + 950) / 3
    }

    /// 模型只看最近 8 秒（最新的在最后）。
    func testKeepsTheLastEightSeconds() {
        var samples = [Int16](repeating: 100, count: 16_000 * 10)
        samples[samples.count - 1] = 8192
        let window = SmartTurn.window(pcm: pcm(samples), sampleRate: 16_000, channels: 1)
        XCTAssertEqual(window.count, SmartTurn.windowSamples)
        XCTAssertEqual(window.last, 0.25)
    }

    func testEmpty() {
        XCTAssertEqual(SmartTurn.window(pcm: Data(), sampleRate: 48_000, channels: 1), [])
    }
}

final class TurnEndWatchTests: XCTestCase {

    /// 0.2 秒问一次；判没说完，静音每长 0.2 秒再问（越静越有把握）；判说完 / 再开口就不问了。
    func testAsksAtPauseThenEveryFifthOfASecond() {
        var watch = TurnEndWatch()
        XCTAssertFalse(watch.due(silence: 0.5))            // 没停顿过：不问
        watch.paused(silence: 0.2)
        XCTAssertTrue(watch.due(silence: 0.2))
        XCTAssertFalse(watch.due(silence: 0.3))
        XCTAssertTrue(watch.due(silence: 0.41))
        XCTAssertFalse(watch.due(silence: 0.5))
        watch.stop()
        XCTAssertFalse(watch.due(silence: 1.0))
    }
}

final class LenientCheckParseTests: XCTestCase {

    /// Qwen 偶尔漏掉字符串开头的引号（2026-09-30 实测，「三百颗牙齿」因此没纠正）。
    func testMissingOpeningQuote() throws {
        let text = #"{"wrong": true, "kind": "clear_error", "confidence": 1.0, "correction": 人一生共有32颗牙齿", "detail": "成年人通常有32颗恒牙"}"#
        XCTAssertEqual(try InterjectionAPI.parseCheck(text),
                       .init(wrong: true, kind: .clearError, confidence: 1, correction: "人一生共有32颗牙齿",
                             detail: "成年人通常有32颗恒牙"))
    }

    func testMissingClosingQuoteAtTheEnd() throws {
        let text = #"{"wrong": true, "kind": "clear_error", "confidence": 0.9, "correction": "一年有12个月", "detail": "一年有十二个月}"#
        let check = try InterjectionAPI.parseCheck(text)
        XCTAssertEqual(check.correction, "一年有12个月")
        XCTAssertEqual(check.detail, "一年有十二个月")
    }

    /// 连 wrong 都认不出来的，照旧当解析失败（宁可不插）。
    func testNoWrongFieldStillFails() {
        XCTAssertThrowsError(try InterjectionAPI.parseCheck(#"{"kind": "clear_error", "correction": 苹果}"#))
    }
}

final class LiveRouteTests: XCTestCase {

    /// 边听边插话只纠错：两个人的话并成一段时带着问句也照样核对（「……对身体好。对了，日本的首都是大阪吧？」
    /// question 0.76、claim 0.94，按原来的分流是「提问」，大阪就漏了）。
    func testLiveChecksAnyClaim() {
        XCTAssertEqual(InterjectionAPI.Gate(complete: 0.8, claim: 0.94, question: 0.76).liveRoute, .check)
        XCTAssertEqual(InterjectionAPI.Gate(complete: 0.8, claim: 0.9, task: 0.9).liveRoute, .check)
        XCTAssertEqual(InterjectionAPI.Gate(complete: 0.8, claim: 0.2, question: 0.9).liveRoute, .none)
    }

    /// Whisper 爱在句尾补个逗号（「一年有13个月,」），Jev 就当没说完了。问之前去掉。
    func testTrailingCommaIsNotASignalOfIncompleteness() {
        XCTAssertEqual(InterjectionAPI.dropTrailingComma("一年有13个月,"), "一年有13个月")
        XCTAssertEqual(InterjectionAPI.dropTrailingComma("水五十度就开了， "), "水五十度就开了")
        XCTAssertEqual(InterjectionAPI.dropTrailingComma("是吗?"), "是吗?")
        XCTAssertEqual(InterjectionAPI.dropTrailingComma("我跟你说、"), "我跟你说")
    }
}

final class FinalTicketTests: XCTestCase {

    /// 收尾的票 Jev 失败了也不能丢（App 就不看门槛直接核对）；试探票失败了等下一次就行。
    func testPromotedTicketIsFinal() {
        var t = LiveUtteranceTracker()
        let a = t.pause()
        XCTAssertFalse(t.isFinal(a))
        guard case .awaiting(let promoted) = t.cut() else { return XCTFail("应该等在路上的那张") }
        XCTAssertTrue(t.isFinal(promoted))
        _ = t.transcribed(promoted, text: "日本的首都是大阪吧")
        XCTAssertEqual(t.judged(promoted, gate: .init(complete: 1, claim: 1)), .commit(final: true))
        XCTAssertFalse(t.isFinal(promoted))
    }
}

final class ContinuationTests: XCTestCase {

    /// 纠正准备好时，停顿后 0.5 秒内就有人接着说 → 多半是本人没说完，先听一下（「水五十度就开了，哦不对……」
    /// 停了 0.32 秒就接着说，2026-10-01 模拟里纠正念到了他改口的时候）。隔得久的是对方在接话，不等。
    func testQuickContinuationIsHeardFirst() {
        XCTAssertTrue(InterjectionPolicy.continuesQuickly(pauseStartedAt: 10, speechStarts: [8, 10.32]))
        XCTAssertFalse(InterjectionPolicy.continuesQuickly(pauseStartedAt: 10, speechStarts: [8, 10.7]))
        XCTAssertFalse(InterjectionPolicy.continuesQuickly(pauseStartedAt: 10, speechStarts: [8]))
    }

    func testContinuationThatCorrectsItself() {
        XCTAssertTrue(InterjectionPolicy.correctsItself("哦,不对"))
        XCTAssertTrue(InterjectionPolicy.correctsItself("啊不對"))          // Whisper 吐的繁体
        XCTAssertTrue(InterjectionPolicy.correctsItself("No wait, it's 100"))
        XCTAssertFalse(InterjectionPolicy.correctsItself("真的假的"))
    }
}

final class TagQuestionIsNotSelfCorrectionTests: XCTestCase {
    func testShiBuShiIsAQuestionNotACorrection() {
        XCTAssertFalse(InterjectionPolicy.correctsItself("太阳是不是"))
        XCTAssertFalse(InterjectionPolicy.correctsItself("这样挺好的，不是吗"))
        XCTAssertTrue(InterjectionPolicy.correctsItself("啊不是，是东京"))
    }
}

final class BargeInTests: XCTestCase {
    func testUnfinishedClaimIsCheckedWhenConfident() {
        XCTAssertTrue(BargeIn.checksUnfinished(InterjectionAPI.Gate(complete: 0.3, claim: 0.8)))
        XCTAssertFalse(BargeIn.checksUnfinished(InterjectionAPI.Gate(complete: 0.3, claim: 0.55)))
    }

    func testWholeSentenceAfterInterruptionIsNotCheckedAgain() {
        let interrupted = ["苹果是一种蔬菜,"]
        XCTAssertTrue(BargeIn.alreadyInterrupted("苹果是一种蔬菜，我每天都吃", interrupted: interrupted))
        XCTAssertFalse(BargeIn.alreadyInterrupted("一年有十三个月", interrupted: interrupted))
        XCTAssertFalse(BargeIn.alreadyInterrupted("随便说说", interrupted: ["，"]))
    }

    func testInterruptPhraseFollowsTheCorrectionLanguage() {
        XCTAssertEqual(BargeIn.interruptPhrase(for: "苹果是水果"), "等一下，")
        XCTAssertEqual(BargeIn.interruptPhrase(for: "富士山は本州にある"), "ちょっと待って、")
        XCTAssertEqual(BargeIn.interruptPhrase(for: "Light is faster"), "Wait, ")
        XCTAssertEqual(BargeIn.followUpPhrase(for: "鲸鱼是哺乳动物"), "还有，")
    }

    func testCorrectionIsReadWithItsReason() {
        XCTAssertEqual(BargeIn.explained("苹果是水果。", detail: "它是苹果树结的果实"), "苹果是水果，它是苹果树结的果实")
        XCTAssertEqual(BargeIn.explained("富士山は本州にある", detail: "静岡と山梨の境です"), "富士山は本州にある。静岡と山梨の境です")
        XCTAssertEqual(BargeIn.explained("苹果是水果", detail: " "), "苹果是水果")
    }
}

final class CorrectionQueueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCorrectionsInARowAreSpokenInOrder() {
        var queue = CorrectionQueue()
        queue.push(correction: "地球绕着太阳转", spoken: "地球绕着太阳转", now: t0)
        queue.push(correction: "鲸鱼是哺乳动物", spoken: "鲸鱼是哺乳动物", now: t0.addingTimeInterval(1))
        XCTAssertEqual(queue.pop(now: t0.addingTimeInterval(2))?.correction, "地球绕着太阳转")
        XCTAssertEqual(queue.pop(now: t0.addingTimeInterval(4))?.correction, "鲸鱼是哺乳动物")
        XCTAssertNil(queue.pop(now: t0.addingTimeInterval(5)))
    }

    func testStaleCorrectionsAreDropped() {
        var queue = CorrectionQueue()
        queue.push(correction: "旧的", spoken: "旧的", now: t0)
        queue.push(correction: "新的", spoken: "新的", now: t0.addingTimeInterval(5))
        XCTAssertEqual(queue.pop(now: t0.addingTimeInterval(CorrectionQueue.maxWait + 1))?.correction, "新的")
    }

    func testNoCooldownWhenQueued() {
        var policy = InterjectionPolicy()
        let check = InterjectionAPI.Check(wrong: true, kind: .clearError, confidence: 1, correction: "苹果是水果", detail: "")
        let other = InterjectionAPI.Check(wrong: true, kind: .clearError, confidence: 1, correction: "一年有12个月", detail: "")
        XCTAssertEqual(policy.decide(check, delay: 1, laterSegments: [], now: t0, cooldown: 0), .show(correction: "苹果是水果"))
        XCTAssertEqual(policy.decide(other, delay: 1, laterSegments: [], now: t0.addingTimeInterval(1), cooldown: 0),
                       .show(correction: "一年有12个月"))
    }
}
