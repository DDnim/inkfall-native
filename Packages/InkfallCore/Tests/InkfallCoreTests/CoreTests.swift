import XCTest
@testable import InkfallCore

// 从 inkfall-app 的 regression_tests.rs 移植过来的纯逻辑回归。
// 这些是重写期间唯一的安全网 —— 它们必须先绿，实现才谈得上等价。

// MARK: - 会话状态机

final class SessionMachineTests: XCTestCase {

    func testDictationPastesAndDoesNotScan() {
        XCTAssertEqual(SessionMachine.routeTake(sink: .paste, scanning: false),
                       TakeRouting(scanForCommand: false, destination: .paste))
    }

    func testNoteModeKeepsTextAndDoesNotScan() {
        XCTAssertEqual(SessionMachine.routeTake(sink: .noteWindow, scanning: false),
                       TakeRouting(scanForCommand: false, destination: .note))
    }

    /// 扫描与 sink 正交：以前这个组合根本到不了。
    func testScanningWithNoteStillKeepsTheText() {
        XCTAssertEqual(SessionMachine.routeTake(sink: .noteWindow, scanning: true),
                       TakeRouting(scanForCommand: true, destination: .note))
    }

    /// 退化但可达（会话拆除过程中）：必须静默，不能落回粘贴。
    func testDiscardWithoutScanningKeepsNothingAndPastesNothing() {
        XCTAssertEqual(SessionMachine.routeTake(sink: .discard, scanning: false),
                       TakeRouting(scanForCommand: false, destination: .discard))
    }

    func testNoteTogglePicksTheRightAction() {
        XCTAssertEqual(SessionMachine.noteToggle(.idle), .start)

        let noteRunning = SessionShape(recording: true, sink: .noteWindow)
        XCTAssertEqual(SessionMachine.noteToggle(noteRunning), .stop)

        let hold = SessionShape(recording: true, hold: true, sink: .paste)
        XCTAssertEqual(SessionMachine.noteToggle(hold), .convertHold)

        let scanOnly = SessionShape(recording: true, sink: .discard, scanning: true)
        XCTAssertEqual(SessionMachine.noteToggle(scanOnly), .attachToScan)

        // 真听写占着麦：说明原因，别静默失败。
        let dictating = SessionShape(recording: true, sink: .paste)
        XCTAssertEqual(SessionMachine.noteToggle(dictating), .busyDictating)
    }

    /// 释放一个 sink 时，只有没人要了才真正停 recorder。
    /// 停早了会把另一个消费者从句子中间切断。
    func testReleasingASinkStopsOnlyWhenNobodyIsLeft() {
        XCTAssertEqual(SessionMachine.sinkAfterRelease(otherConsumerActive: true), .discard)
        XCTAssertNil(SessionMachine.sinkAfterRelease(otherConsumerActive: false))
    }

    /// 切段是关键词可见的前提，所以扫描活着时切段器不能拆。
    func testSegmenterOutlivesTheNoteSinkWhileScanning() {
        XCTAssertFalse(SessionMachine.mayStopSegmenter(scanning: true))
        XCTAssertTrue(SessionMachine.mayStopSegmenter(scanning: false))
    }

    func testCommandUtterancesAreMarkedInTheNote() {
        XCTAssertEqual(SessionMachine.noteBody(transcript: "  小明 打开终端 ", wasCommandHit: true),
                       ">> 小明 打开终端")
        XCTAssertEqual(SessionMachine.noteBody(transcript: "  今天的会议纪要 ", wasCommandHit: false),
                       "今天的会议纪要")
    }
}

// MARK: - 有序粘贴队列

final class OrderedPasteQueueTests: XCTestCase {

    func testLoneSubmissionPastesImmediately() {
        var q = OrderedPasteQueue<String>()
        let s = q.enqueue()
        q.complete(seq: s, item: "only")
        XCTAssertEqual(q.takeReadyPrefix(), ["only"])
        XCTAssertEqual(q.outstanding, 0)
    }

    /// 核心 bug：短录音（seq2）比长录音（seq1）先完成。
    /// seq1 没好之前什么都不能粘，然后两者按顺序粘。
    func testOutOfOrderCompletionHoldsUntilHeadThenDrainsInOrder() {
        var q = OrderedPasteQueue<String>()
        let s1 = q.enqueue()   // 1 分钟的录音
        let s2 = q.enqueue()   // 2 秒的录音，后提交

        q.complete(seq: s2, item: "short")
        XCTAssertTrue(q.takeReadyPrefix().isEmpty, "绝不能插到 seq1 前面")

        q.complete(seq: s1, item: "long")
        XCTAssertEqual(q.takeReadyPrefix(), ["long", "short"])
        XCTAssertEqual(q.outstanding, 0)
    }

    func testSkipDoesNotBlockFollowingPaste() {
        var q = OrderedPasteQueue<String>()
        let s1 = q.enqueue()
        let s2 = q.enqueue()
        q.complete(seq: s2, item: "second")
        XCTAssertTrue(q.takeReadyPrefix().isEmpty)
        q.skip(seq: s1)                       // 编辑前发送 / 失败
        XCTAssertEqual(q.takeReadyPrefix(), ["second"])
    }

    /// 恢复的段沿用上一轮的 id；新队列必须跳过去，
    /// 否则撞车会让新 take 原地覆盖一个已恢复的旧块。
    func testAdvancePastPreventsRestoredIDReuse() {
        var q = OrderedPasteQueue<String>()
        q.advancePast(7)
        let s = q.enqueue()
        XCTAssertEqual(s, 8)
        q.complete(seq: s, item: "fresh")
        XCTAssertEqual(q.takeReadyPrefix(), ["fresh"], "队头要跟着一起前移")
    }

    func testHeadAdvancesAcrossMultipleDrains() {
        var q = OrderedPasteQueue<String>()
        let s1 = q.enqueue(), s2 = q.enqueue(), s3 = q.enqueue()
        q.complete(seq: s1, item: "a")
        XCTAssertEqual(q.takeReadyPrefix(), ["a"])
        q.complete(seq: s3, item: "c")
        XCTAssertTrue(q.takeReadyPrefix().isEmpty)
        q.complete(seq: s2, item: "b")
        XCTAssertEqual(q.takeReadyPrefix(), ["b", "c"])
    }
}

// MARK: - 自动断句

final class SilenceSegmenterTests: XCTestCase {

    private let frame = 0.05          // 50 ms 采样，与协调器一致
    private let speech: Float = 0.05
    private let silence: Float = 0.0

    /// 恒定电平喂 `seconds` 秒，返回这期间有没有切过。
    private func feed(_ seg: inout SilenceSegmenter, _ level: Float, _ seconds: Double) -> Bool {
        var cut = false
        for _ in 0..<Int((seconds / frame).rounded()) {
            if seg.feed(level: level, delta: frame) { cut = true }
        }
        return cut
    }

    func testLeadingSilenceNeverCuts() {
        var seg = SilenceSegmenter()
        XCTAssertFalse(feed(&seg, silence, 30))
    }

    func testPauseAfterSpeechCutsExactlyOnce() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)      // 冷启动播种
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertTrue(feed(&seg, silence, 1.5))         // ~1.3 s 静音切一次
        XCTAssertFalse(feed(&seg, silence, 10))         // 持续静音不再触发
    }

    func testShortPauseMidSpeechDoesNotCut() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertFalse(feed(&seg, silence, 0.8))        // < 1.3 s
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertFalse(feed(&seg, silence, 0.8))
    }

    func testSpeechAfterCutRearmsForTheNextPause() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        XCTAssertTrue(feed(&seg, silence, 1.5))
        _ = feed(&seg, speech, 1.0)
        XCTAssertTrue(feed(&seg, silence, 1.5))
    }

    func testStrayNoiseBelowMinSpeechDoesNotArm() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        XCTAssertFalse(feed(&seg, speech, 0.2))         // < minSpeechSeconds
        XCTAssertFalse(feed(&seg, silence, 5))
    }

    func testResetSegmentClearsArming() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        seg.resetSegment()
        XCTAssertFalse(feed(&seg, silence, 5), "手动切段后，静音不该在空段上再切")
    }

    func testNonPositiveDeltaIsIgnored() {
        var seg = SilenceSegmenter()
        XCTAssertFalse(seg.feed(level: speech, delta: 0))
        XCTAssertFalse(seg.feed(level: speech, delta: -1))
    }
}

// MARK: - 提交策略 / WAV

final class SubmissionPolicyTests: XCTestCase {

    /// 造一段 16 bit 单声道 WAV：`speechMs` 毫秒的满响，其余静音。
    private func wav(totalMs: Int, speechMs: Int, sampleRate: UInt32 = 16000) -> Data {
        let total = Int(sampleRate) * totalMs / 1000
        let loud = Int(sampleRate) * speechMs / 1000
        var pcm = Data(capacity: total * 2)
        for i in 0..<total {
            let v: Int16 = i < loud ? 12000 : 0
            pcm.append(UInt8(UInt16(bitPattern: v) & 0xff))
            pcm.append(UInt8((UInt16(bitPattern: v) >> 8) & 0xff))
        }
        return WAV.encode(pcm: pcm, sampleRate: sampleRate, channels: 1)
    }

    func testShortRecordingsDoNotSubmit() {
        let p = RecordingSubmissionPolicy.default
        let short = RecordedAudio(data: wav(totalMs: 400, speechMs: 400), durationMs: 400)
        XCTAssertEqual(p.verdict(for: short), .tooShort)

        let tiny = RecordedAudio(data: Data(count: 100), durationMs: 5000)
        XCTAssertEqual(p.verdict(for: tiny), .tooShort)
    }

    func testSilentRecordingIsRejected() {
        let p = RecordingSubmissionPolicy.default
        let quiet = RecordedAudio(data: wav(totalMs: 3000, speechMs: 0), durationMs: 3000)
        XCTAssertEqual(p.verdict(for: quiet), .silent)
    }

    func testAudibleRecordingSubmits() {
        let p = RecordingSubmissionPolicy.default
        let spoken = RecordedAudio(data: wav(totalMs: 3000, speechMs: 900), durationMs: 3000)
        XCTAssertEqual(p.verdict(for: spoken), .submit)
    }

    /// 解析不出来必须 fail-open —— 绝不能因为容器格式意外而丢掉真实语音。
    func testUnparseableAudioFailsOpen() {
        let p = RecordingSubmissionPolicy.default
        let junk = RecordedAudio(data: Data(repeating: 0xAB, count: 8000), durationMs: 3000)
        XCTAssertEqual(p.verdict(for: junk), .submit)
    }

    func testWAVRoundTrip() {
        let pcm = Data(repeating: 7, count: 1600)
        let encoded = WAV.encode(pcm: pcm, sampleRate: 16000, channels: 1)
        let info = WAV.parse(encoded)
        XCTAssertEqual(info?.sampleRate, 16000)
        XCTAssertEqual(info?.channels, 1)
        XCTAssertEqual(info?.dataRange.count, 1600)
    }
}

// MARK: - 静音压缩

final class SilenceTrimmerTests: XCTestCase {

    func testTrimmingCondensesLongPauses() {
        let rate = 16000.0
        func frames(_ ms: Int, loud: Bool) -> Data {
            var d = Data()
            for _ in 0..<(Int(rate) * ms / 1000) {
                let v: Int16 = loud ? 12000 : 0
                d.append(UInt8(UInt16(bitPattern: v) & 0xff))
                d.append(UInt8((UInt16(bitPattern: v) >> 8) & 0xff))
            }
            return d
        }
        // 说 500ms → 停 6s → 再说 500ms
        var pcm = frames(500, loud: true)
        pcm.append(frames(6000, loud: false))
        pcm.append(frames(500, loud: true))

        let result = SilenceTrimmer.default.trim(pcm: pcm, sampleRate: rate, channelCount: 1)
        XCTAssertGreaterThan(result.removedMs, 3000, "6 秒的停顿应该被压到 2 秒左右")
        XCTAssertLessThan(result.keptMs, 4000)
        XCTAssertGreaterThan(result.keptMs, 1000, "两段语音本身必须留着")
    }

    /// 全静音原样返回，让提交策略去给出「静音」裁决。
    func testFullySilentInputIsUnchanged() {
        let pcm = Data(count: 32000)
        let result = SilenceTrimmer.default.trim(pcm: pcm, sampleRate: 16000, channelCount: 1)
        XCTAssertEqual(result.removedMs, 0)
        XCTAssertEqual(result.pcm.count, pcm.count)
    }
}

// MARK: - 本地润色

final class BasicPolisherTests: XCTestCase {

    func testRemovesFillersAndAddsTerminalPunctuation() {
        XCTAssertEqual(BasicPolisher.polish("嗯，这个功能啊已经做好了"), "这个功能已经做好了。")
    }

    func testEnglishFillersAreWholeWordsOnly() {
        XCTAssertEqual(BasicPolisher.polish("um the build is uh green"), "the build is green.")
        // "um" 在 "umbrella" 里不能被删。
        XCTAssertTrue(BasicPolisher.polish("the umbrella is here").contains("umbrella"))
    }

    func testLaughterOnlyCollapsesWhenRepeated() {
        XCTAssertFalse(BasicPolisher.polish("哈哈哈这太好笑了").contains("哈哈"))
        // 单个「哈」在真实词里要留着。
        XCTAssertTrue(BasicPolisher.polish("我买了哈密瓜").contains("哈密瓜"))
    }

    func testTrailingCommaBecomesFullStop() {
        XCTAssertEqual(BasicPolisher.polish("先这样，"), "先这样。")
        XCTAssertEqual(BasicPolisher.polish("ok then,"), "ok then.")
    }

    func testExistingTerminatorIsLeftAlone() {
        XCTAssertEqual(BasicPolisher.polish("已经好了。"), "已经好了。")
        XCTAssertEqual(BasicPolisher.polish("done!"), "done!")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(BasicPolisher.polish("   "), "")
        XCTAssertEqual(BasicPolisher.polish("嗯嗯嗯"), "")
    }
}

// MARK: - 降级判定

final class FallbackTests: XCTestCase {

    func testOnlyOutagesAreEligible() {
        XCTAssertTrue(CloudFailureKind.network.isFallbackEligible)
        XCTAssertTrue(CloudFailureKind.serverError.isFallbackEligible)
        XCTAssertFalse(CloudFailureKind.auth.isFallbackEligible)
        XCTAssertFalse(CloudFailureKind.quota.isFallbackEligible)
        XCTAssertFalse(CloudFailureKind.other.isFallbackEligible)
    }

    func testStatusClassification() {
        XCTAssertEqual(CloudFailureKind.classify(status: 500), .serverError)
        XCTAssertEqual(CloudFailureKind.classify(status: 503), .serverError)
        XCTAssertEqual(CloudFailureKind.classify(status: 401), .auth)
        XCTAssertEqual(CloudFailureKind.classify(status: 403), .auth)
        XCTAssertEqual(CloudFailureKind.classify(status: 402), .quota)
        XCTAssertEqual(CloudFailureKind.classify(status: 400), .other)
    }

    /// 中断降级、账号问题浮出来 —— 静默的本地重试会掩盖一个用户必须处理的问题。
    func testAccountProblemsSurfaceInsteadOfFallingBack() {
        XCTAssertTrue(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .serverError, localModelReady: true))
        XCTAssertFalse(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .quota, localModelReady: true))
        // 本地模型没准备好也不降级 —— 要抛原来的云错误。
        XCTAssertFalse(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .network, localModelReady: false))
        // 加工降级不需要任何已下载模型（basic 全本地）。
        XCTAssertTrue(FallbackPolicy.shouldFallbackPostProcessing(
            autoLocalFallbackEnabled: true, kind: .network))
        XCTAssertFalse(FallbackPolicy.shouldFallbackPostProcessing(
            autoLocalFallbackEnabled: false, kind: .network))
    }
}

// MARK: - 语言归一化

final class LanguageTests: XCTestCase {

    func testDetectedNormalization() {
        for raw in ["zh", "zh-CN", "cmn", "chinese", "中文", "  ZH  "] {
            XCTAssertEqual(TranscriptionLanguage.detected(raw), .zh, "\(raw)")
        }
        for raw in ["en", "en-US", "eng", "English"] {
            XCTAssertEqual(TranscriptionLanguage.detected(raw), .en, "\(raw)")
        }
        for raw in ["ja", "jpn", "日本語"] {
            XCTAssertEqual(TranscriptionLanguage.detected(raw), .ja, "\(raw)")
        }
        // 翻译目标按前导 ISO 段匹配，这样 pt-BR 也能落到正确的一侧。
        XCTAssertEqual(TranscriptionLanguage.detected("pt-BR"), .pt)
        XCTAssertEqual(TranscriptionLanguage.detected("ko"), .ko)
        XCTAssertNil(TranscriptionLanguage.detected(""))
        XCTAssertNil(TranscriptionLanguage.detected("klingon"))
    }
}

// MARK: - 设置的容错解码

final class SettingsDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// 缺失字段只回落**那一个**，用户其他设置必须活下来。
    func testMissingFieldsFallBackIndividually() throws {
        let s = try decode(#"{"postProcessingEnabled": true, "noteAutoPaste": true}"#)
        XCTAssertTrue(s.postProcessingEnabled)
        XCTAssertTrue(s.noteAutoPaste)
        XCTAssertTrue(s.focusEditorAfterInsert, "没提到的字段用默认值")
        XCTAssertEqual(s.fixedTranscriptionLanguage, .zh)
    }

    /// 类型错也只影响那一个字段。
    func testWrongTypesFallBackIndividually() throws {
        let s = try decode(#"{"micGainBoostTargetPercent": "loud", "recentContextEnabled": false}"#)
        XCTAssertEqual(s.micGainBoostTargetPercent, 80)
        XCTAssertFalse(s.recentContextEnabled)
    }

    /// ⚠️ 与其他字段相反：缺 `hasCompletedOnboarding` 说明是老用户，
    /// 不该再弹一次引导。
    func testMissingOnboardingFlagMeansAlreadyOnboarded() throws {
        XCTAssertTrue(try decode(#"{"appLanguage": "zh"}"#).hasCompletedOnboarding)
        XCTAssertFalse(try decode(#"{"hasCompletedOnboarding": false}"#).hasCompletedOnboarding)
    }

    func testSanitizeResetsUnknownModelIDs() {
        var s = AppSettings()
        s.selectedGroqModel = "whisper-from-the-future"
        s.selectedLocalModelId = "nope"
        s.preferredTranscriptionLanguages = []
        s.processingMemoryContext = String(repeating: "字", count: 9000)
        s.sanitize()
        XCTAssertEqual(s.selectedGroqModel, "whisper-large-v3-turbo")
        XCTAssertEqual(s.selectedLocalModelId, "whisper-base")
        XCTAssertEqual(s.preferredTranscriptionLanguages, [.zh, .en, .ja])
        XCTAssertEqual(s.processingMemoryContext.count, 8000)
    }

    /// 原生版换了推理运行时，模型 id 表跟着变。旧 id 要**迁移**到体量相当的
    /// 新档位，而不是一律回落默认 —— 后者会把用户选过的档位悄悄降级。
    func testLocalModelIDMigration() {
        XCTAssertEqual(LocalModels.migrate(id: "whisper-tiny"), "whisper-tiny")
        XCTAssertEqual(LocalModels.migrate(id: "whisper-medium"), "whisper-turbo")
        XCTAssertEqual(LocalModels.migrate(id: LocalModels.mossID), "whisper-turbo")
        XCTAssertEqual(LocalModels.migrate(id: "nope"), "whisper-base")
        for model in LocalModels.all {
            XCTAssertEqual(LocalModels.migrate(id: model.id), model.id)
            XCTAssertFalse(model.variant.isEmpty)
        }
    }

    /// 一个操作者驱动整条流水线；local 是例外。
    func testSanitizeAlignsProcessingProviderWithTranscription() {
        var s = AppSettings()
        s.transcriptionMode = .gemini
        s.postProcessingProvider = .openai
        s.sanitize()
        XCTAssertEqual(s.postProcessingProvider, .gemini)

        s.transcriptionMode = .local
        s.postProcessingProvider = .groq
        s.sanitize()
        XCTAssertEqual(s.postProcessingProvider, .groq, "本地不能加工，保留独立选择")
    }

    /// 落笔的 AI 开关/预设覆盖全局的，其余字段原样带过。
    func testNoteEffectiveOverridesOnlyPostProcessing() {
        var s = AppSettings()
        s.postProcessingEnabled = false
        s.postProcessingPreset = .summary
        s.noteProcessingEnabled = true
        s.noteProcessingPreset = .notes
        s.focusEditorAfterInsert = false

        let derived = s.noteEffective()
        XCTAssertTrue(derived.postProcessingEnabled)
        XCTAssertEqual(derived.postProcessingPreset, .notes)
        XCTAssertFalse(derived.focusEditorAfterInsert, "无关字段原样带过")
        XCTAssertFalse(s.postProcessingEnabled, "源设置不被改动")
    }

    /// 说话人标签只在本地 MOSS 管线上存在。
    func testSpeakerLabelsRequireLocalMoss() {
        var s = AppSettings()
        s.noteSpeakerDiarizationEnabled = true
        s.transcriptionMode = .groqProxy
        XCTAssertFalse(s.noteWantsSpeakerLabels)

        s.transcriptionMode = .local
        s.selectedLocalModelId = "whisper-tiny"
        XCTAssertFalse(s.noteWantsSpeakerLabels)

        s.selectedLocalModelId = LocalModels.mossID
        XCTAssertTrue(s.noteWantsSpeakerLabels)
    }
}

// MARK: - 快捷键

final class ShortcutsTests: XCTestCase {

    private func decode(_ json: String) throws -> ShortcutsConfig {
        try JSONDecoder().decode(ShortcutsConfig.self, from: Data(json.utf8))
    }

    private var noteSpace: Set<UInt16> { [61, 49] }

    func testNoteModeDefaultIsOptionSpace() {
        XCTAssertEqual(ShortcutsConfig().noteMode.normalizedKeycodes, noteSpace)
    }

    /// 早于落笔的配置：只有 overlayToggle，没有 noteMode。
    /// 死掉的 overlayToggle 被忽略，落笔落到 ⌥Space。
    func testOldConfigWithoutNoteModeMigrates() throws {
        let cfg = try decode(#"""
        {"overlayToggle":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":43,"label":","}]}}
        """#)
        XCTAssertEqual(cfg.noteMode.normalizedKeycodes, noteSpace)
    }

    /// 中间版本把 noteMode 存成了旧的 ⌥, —— 也要迁走（⌥, 靠别名继续可用）。
    func testInterimNoteModeOnCommaMigrates() throws {
        let cfg = try decode(#"""
        {"noteMode":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":43,"label":","}]}}
        """#)
        XCTAssertEqual(cfg.noteMode.normalizedKeycodes, noteSpace)
    }

    /// 用户自定义的绑定必须尊重。
    func testCustomNoteModeBindingIsRespected() throws {
        let cfg = try decode(#"""
        {"noteMode":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":47,"label":"."}]}}
        """#)
        XCTAssertEqual(cfg.noteMode.normalizedKeycodes, [61, 47])
    }

    /// 真实用户的 shortcuts.json：自定义的 historyPicker 要保住。
    func testRealUserConfigKeepsCustomHistoryBinding() throws {
        let cfg = try decode(#"""
        {"cancelRecording":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":53,"label":"Esc"}]},
         "historyPicker":{"keys":[{"keycode":56,"label":"Shift"},{"keycode":55,"label":"Command"},{"keycode":5,"label":"G"}]},
         "overlayToggle":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":43,"label":","}]}}
        """#)
        XCTAssertEqual(cfg.noteMode.normalizedKeycodes, noteSpace)
        XCTAssertEqual(cfg.historyPicker.normalizedKeycodes, [56, 55, 5])
    }

    func testNormalizationFoldsLeftRightButNotRightOption() {
        XCTAssertEqual(Shortcut.normalize(54), 55)
        XCTAssertEqual(Shortcut.normalize(60), 56)
        XCTAssertEqual(Shortcut.normalize(62), 59)
        XCTAssertEqual(Shortcut.normalize(61), 61, "右 ⌥ 是独立可绑定的键")
    }

    func testConflictDetection() {
        let cfg = ShortcutsConfig()
        // ⌥[ 已经被 historyPicker 占了。
        XCTAssertEqual(cfg.conflictingSlot(Shortcut([(61, "Right Option"), (33, "[")])),
                       "historyPicker")
        // 跳过自己就不算冲突。
        XCTAssertNil(cfg.conflictingSlot(Shortcut([(61, "Right Option"), (33, "[")]),
                                         skip: "historyPicker"))
        XCTAssertNil(cfg.conflictingSlot(.empty), "空快捷键永不冲突")
    }

    func testSystemReservedDetection() {
        XCTAssertTrue(ShortcutsConfig.isSystemReserved(Shortcut([(55, "Command"), (49, "Space")])))
        XCTAssertTrue(ShortcutsConfig.isSystemReserved(Shortcut([(55, "Command"), (48, "Tab")])))
        XCTAssertFalse(ShortcutsConfig.isSystemReserved(Shortcut([(61, "Right Option"), (49, "Space")])))
    }

    func testUsesFnScansEveryShortcutSlot() {
        var cfg = ShortcutsConfig()
        XCTAssertFalse(cfg.usesFn)
        cfg.editBeforeSendPresets.polish = Shortcut([(63, "Fn"), (35, "P")])
        XCTAssertTrue(cfg.usesFn, "per-preset 的快捷键也要算进去")
    }

    func testPredatesNoteSpaceDetection() {
        XCTAssertTrue(ShortcutsConfig.predatesNoteSpace(
            json: Data(#"{"overlayToggle":{"keys":[]}}"#.utf8)))
        XCTAssertTrue(ShortcutsConfig.predatesNoteSpace(json: Data("{}".utf8)))
        XCTAssertTrue(ShortcutsConfig.predatesNoteSpace(json: Data(#"""
            {"noteMode":{"keys":[{"keycode":61},{"keycode":43}]}}
            """#.utf8)))
        XCTAssertFalse(ShortcutsConfig.predatesNoteSpace(json: Data(#"""
            {"noteMode":{"keys":[{"keycode":61},{"keycode":49}]}}
            """#.utf8)))
    }
}

// MARK: - 落笔会话

final class NoteSessionTests: XCTestCase {

    func testUpsertUpdatesInPlaceAndPreservesPasted() {
        var s = NoteSession()
        s.upsert(id: 1, raw: "", final: "", status: .processing)
        s.markPasted([1])
        s.upsert(id: 1, raw: "raw", final: "final", status: .done)
        XCTAssertEqual(s.segments.count, 1, "占位块应该原地变成 done")
        XCTAssertEqual(s.segments[0].finalText, "final")
        XCTAssertTrue(s.segments[0].pasted, "pasted 标记要活过更新")
    }

    func testPasteAllSelectsUnpastedDoneInIDOrder() {
        var s = NoteSession()
        s.upsert(id: 3, raw: "c", final: "c", status: .done)
        s.upsert(id: 1, raw: "a", final: "a", status: .done)
        s.upsert(id: 2, raw: "b", final: "b", status: .failed)
        s.upsert(id: 4, raw: "d", final: "d", status: .done)
        s.markPasted([1])
        let items = s.unpastedDoneInOrder()
        XCTAssertEqual(items.map(\.id), [3, 4])
        XCTAssertEqual(items.map(\.text), ["c", "d"])
    }

    func testNthFromLastDoneCountsAllDoneSegments() {
        var s = NoteSession()
        s.upsert(id: 1, raw: "a", final: "a", status: .done)
        s.upsert(id: 2, raw: "b", final: "b", status: .failed)
        s.upsert(id: 3, raw: "c", final: "c", status: .done)
        s.markPasted([1])                              // 已粘贴的仍然计数
        XCTAssertEqual(s.nthFromLastDone(1)?.text, "c")
        XCTAssertEqual(s.nthFromLastDone(2)?.text, "a")
        XCTAssertNil(s.nthFromLastDone(3))
        XCTAssertNil(s.nthFromLastDone(0))
    }

    func testIsSettledTracksUnpastedDone() {
        var s = NoteSession()
        XCTAssertTrue(s.isSettled)
        s.upsert(id: 1, raw: "a", final: "a", status: .done)
        XCTAssertFalse(s.isSettled)
        s.markPasted([1])
        XCTAssertTrue(s.isSettled)
        s.upsert(id: 2, raw: "", final: "", status: .failed)
        XCTAssertTrue(s.isSettled, "失败的段没有东西可粘")
    }

    /// `processing` 永不落盘 —— 重启不可能续上一次在飞的转写。
    func testPersistableDropsProcessingSegments() throws {
        var s = NoteSession()
        s.sessionEntryId = "NOTE-1"
        s.upsert(id: 1, raw: "a", final: "a", status: .done)
        s.upsert(id: 2, raw: "", final: "", status: .processing)

        let data = try JSONEncoder().encode(s.persistable())
        var reloaded = try JSONDecoder().decode(NoteSession.self, from: data)
        reloaded.dropProcessing()
        XCTAssertEqual(reloaded.segments.count, 1)
        XCTAssertEqual(reloaded.segments[0].id, 1)
        XCTAssertEqual(reloaded.sessionEntryId, "NOTE-1")
    }

    func testDisplayTextFallsBackToRaw() {
        let seg = NoteSessionSegment(id: 1, rawText: "raw", finalText: "", status: .done)
        XCTAssertEqual(seg.displayText, "raw")
    }

    func testClearResetsStartedAt() {
        var s = NoteSession()
        s.upsert(id: 1, raw: "a", final: "a", status: .done)
        XCTAssertNotNil(s.startedAtMs)
        s.clear()
        XCTAssertNil(s.startedAtMs)
        XCTAssertTrue(s.segments.isEmpty)
    }
}

// MARK: - 笔记条目

final class HistoryEntryTests: XCTestCase {

    /// 老条目没有 title / speakerNames，必须能加载并补上默认标题。
    func testTolerantDecodingBackfillsTitle() throws {
        let json = #"""
        {"id":"X","createdAtMs":1750000000000,"sourceText":"raw","finalText":"final",
         "transcriptionMode":"groq","postProcessingEnabled":true}
        """#
        let e = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.id, "X")
        XCTAssertFalse(e.title.isEmpty, "空标题要补成创建时刻")
        XCTAssertEqual(e.displayText, "final")
        XCTAssertTrue(e.speakerNames.isEmpty)
    }

    func testDisplayTextFallsBackToSource() {
        let e = HistoryEntry(sourceText: "raw", finalText: "")
        XCTAssertEqual(e.displayText, "raw")
    }
}
