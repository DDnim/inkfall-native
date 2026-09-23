import XCTest
@testable import InkfallCore

// 从 inkfall-app 的 regression_tests.rs 移植过来的纯逻辑回归。
// 这些是重写期间唯一的安全网 —— 它们必须先绿，实现才谈得上等价。

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

    /// 造一段 16 bit 单声道正弦：更接近真实语音的波形 —— 关键在于**瞬时采样
    /// 绝大多数贴近零**，正是旧判据栽跟头的地方。
    private func tone(totalMs: Int, amplitude: Float, sampleRate: UInt32 = 16000,
                      frequency: Double = 220) -> Data {
        let total = Int(sampleRate) * totalMs / 1000
        var pcm = Data(capacity: total * 2)
        for i in 0..<total {
            let phase = 2 * Double.pi * frequency * Double(i) / Double(sampleRate)
            let v = Int16(Double(amplitude) * Double(Int16.max) * sin(phase))
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

    /// 一段安静但**真的有人在说话**的录音必须过。
    ///
    /// ⚠️ 这条是真实事故换来的（2026-08-05，AMI 会议语料实测）：旧判据数的是
    /// 「瞬时振幅 > 0.02 的采样累计 ≥150ms」，而语音波形绝大多数瞬时采样都
    /// 贴近零 —— 17.5 分钟的真实会议里 **71 段有 34 段被判「没声音」丢掉，
    /// 其中 23 段真的有人在说话**，包括一段 19.5 秒的需求陈述（它的「有效
    /// 采样」只有 17 ms）。判据换成窗口 RMS 峰值之后才分得开。
    func testQuietButRealSpeechSubmits() {
        let p = RecordingSubmissionPolicy.default
        // 峰值 0.05 满量程的正弦 —— 说话声不大，但远高于室内底噪。
        let quiet = RecordedAudio(data: tone(totalMs: 3000, amplitude: 0.05),
                                  durationMs: 3000)
        XCTAssertEqual(p.verdict(for: quiet), .submit)
    }

    /// 而室内底噪（0.004–0.006 这一档）仍然必须被挡掉 —— 否则 Whisper 会对着
    /// 它吐「Thank you.」「谢谢观看」这类幻觉。
    func testRoomToneIsStillRejected() {
        let p = RecordingSubmissionPolicy.default
        let roomTone = RecordedAudio(data: tone(totalMs: 3000, amplitude: 0.004),
                                     durationMs: 3000)
        XCTAssertEqual(p.verdict(for: roomTone), .silent)
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
        let s = try decode(#"{"postProcessingEnabled": true, "pasteAppendNewline": true}"#)
        XCTAssertTrue(s.postProcessingEnabled)
        XCTAssertTrue(s.pasteAppendNewline)
        XCTAssertTrue(s.focusEditorAfterInsert, "没提到的字段用默认值")
        XCTAssertEqual(s.fixedTranscriptionLanguage, .zh)
    }

    /// 老配置里没有 `autoPasteEnabled` 这个键。缺失必须解成 **true** ——
    /// 解成 false 就等于升级之后听写突然不粘了，而用户从没关过它。
    func testMissingAutoPasteFlagKeepsPasting() throws {
        XCTAssertTrue(try decode(#"{"appLanguage": "zh"}"#).autoPasteEnabled)
        XCTAssertFalse(try decode(#"{"autoPasteEnabled": false}"#).autoPasteEnabled)
    }

    /// 类型错也只影响那一个字段。
    func testWrongTypesFallBackIndividually() throws {
        let s = try decode(#"{"micGainBoostTargetPercent": "loud", "autoPasteEnabled": false}"#)
        XCTAssertEqual(s.micGainBoostTargetPercent, 80)
        XCTAssertFalse(s.autoPasteEnabled)
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
        // large 现在是真实存在的一条，不该再被改判成 turbo。
        XCTAssertEqual(LocalModels.migrate(id: "whisper-large"), "whisper-large")
        XCTAssertEqual(LocalModels.definition(id: "whisper-large")?.variant,
                       "openai_whisper-large-v3")
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

}

// MARK: - 快捷键

final class ShortcutsTests: XCTestCase {

    private func decode(_ json: String) throws -> ShortcutsConfig {
        try JSONDecoder().decode(ShortcutsConfig.self, from: Data(json.utf8))
    }

    private var optionSpace: Set<UInt16> { [61, 49] }

    func testDefaults() {
        let cfg = ShortcutsConfig()
        XCTAssertEqual(cfg.overlayHold.normalizedKeycodes, [61])
        XCTAssertEqual(cfg.toggleRecording.normalizedKeycodes, optionSpace)
    }

    /// 减法之前的配置：只有旧槽位，没有 toggleRecording。旧槽静默忽略。
    func testOldConfigWithoutToggleFallsBackToDefault() throws {
        let cfg = try decode(#"""
        {"overlayToggle":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":43,"label":","}]},
         "historyPicker":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":33,"label":"["}]}}
        """#)
        XCTAssertEqual(cfg.toggleRecording.normalizedKeycodes, optionSpace)
        XCTAssertEqual(cfg.overlayHold.normalizedKeycodes, [61])
    }

    /// 用户给「落笔」自定义过的绑定迁到切换录音上。
    func testCustomNoteModeMigratesToToggle() throws {
        let cfg = try decode(#"""
        {"noteMode":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":47,"label":"."}]}}
        """#)
        XCTAssertEqual(cfg.toggleRecording.normalizedKeycodes, [61, 47])
    }

    /// 中间版本把 noteMode 存成了旧的 ⌥, —— 那不是用户的选择，不迁。
    func testInterimCommaNoteModeIsNotMigrated() throws {
        let cfg = try decode(#"""
        {"noteMode":{"keys":[{"keycode":61,"label":"Right Option"},{"keycode":43,"label":","}]}}
        """#)
        XCTAssertEqual(cfg.toggleRecording.normalizedKeycodes, optionSpace)
    }

    /// 写盘只有两个槽；读回来必须一致。
    func testRoundTrip() throws {
        var cfg = ShortcutsConfig()
        cfg.overlayHold = Shortcut([(63, "Fn")])
        cfg.toggleRecording = Shortcut([(63, "Fn"), (49, "Space")])
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(ShortcutsConfig.self, from: data)
        XCTAssertEqual(back, cfg)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["overlayHold", "toggleRecording"])
    }

    func testNormalizationFoldsLeftRightButNotRightOption() {
        XCTAssertEqual(Shortcut.normalize(54), 55)
        XCTAssertEqual(Shortcut.normalize(60), 56)
        XCTAssertEqual(Shortcut.normalize(62), 59)
        XCTAssertEqual(Shortcut.normalize(61), 61, "右 ⌥ 是独立可绑定的键")
    }

    func testConflictDetection() {
        let cfg = ShortcutsConfig()
        XCTAssertEqual(cfg.conflictingSlot(Shortcut([(61, "Right Option"), (49, "Space")])),
                       "toggleRecording")
        XCTAssertNil(cfg.conflictingSlot(Shortcut([(61, "Right Option"), (49, "Space")]),
                                         skip: "toggleRecording"))
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
        cfg.toggleRecording = Shortcut([(63, "Fn"), (49, "Space")])
        XCTAssertTrue(cfg.usesFn)
    }
}

// MARK: - 安静音频上的短套话

final class QuietArtifactTests: XCTestCase {

    /// ⚠️ 靠文本无法消歧：「Thank you.」是人真的会单独说的一句回应。
    /// 判据必须是**音频特征** —— 只有刚刚擦着提交门限过来的安静段落里，
    /// 这句话才是 Whisper 对着近似静音的产物。
    func testShortBoilerplateIsOnlyAHallucinationOnQuietAudio() {
        // 安静（刚过 0.015 的提交门限）+ 短套话 = 幻觉
        XCTAssertTrue(HallucinationFilter.isHallucination("Thank you.", peakLevel: 0.018))
        XCTAssertTrue(HallucinationFilter.isHallucination("谢谢", peakLevel: 0.02))
        XCTAssertTrue(HallucinationFilter.isHallucination("you", peakLevel: 0.016))

        // 同一句话，音频里确实有人在正常说话 → 是真话，必须留着
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you.", peakLevel: 0.12))
        XCTAssertFalse(HallucinationFilter.isHallucination("谢谢", peakLevel: 0.05))
    }

    /// 不知道音量时 fail-open —— 当成真人说的，绝不删用户说过的话。
    func testUnknownLevelKeepsTheText() {
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you."))
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you.", peakLevel: nil))
    }

    /// 安静也好、大声也好，正常内容一律不动。
    func testRealContentSurvivesAtAnyLevel() {
        for level: Float in [0.016, 0.05, 0.4] {
            XCTAssertFalse(HallucinationFilter.isHallucination(
                "First is the functional, what needs need to be fulfilled",
                peakLevel: level))
        }
    }

    /// 字幕组片尾那一类**与音量无关**，永远丢。
    func testSubtitleBoilerplateIsAlwaysDropped() {
        XCTAssertTrue(HallucinationFilter.isHallucination("字幕由 Amara.org 社群提供",
                                                          peakLevel: 0.5))
        XCTAssertTrue(HallucinationFilter.isHallucination("thanks for watching", peakLevel: 0.5))
    }
}

// MARK: - 幻觉名单的实战补充

final class QuietArtifactFieldReportTests: XCTestCase {

    /// 2026-08-05 实测：会议笔记自测跑了 60 秒，麦克风对着安静的房间，
    /// 转写出三段「谢谢大家」并落进了正文。名单里原本只有「谢谢观看」
    /// 这种字幕组片尾，漏了这个最常见的形态。
    func testChineseSilenceArtifactsFromTheField() {
        for text in ["谢谢大家", "謝謝大家", "谢谢你", "好的"] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text, peakLevel: 0.02),
                          "\(text) 在安静音频上应判为幻觉")
            XCTAssertFalse(HallucinationFilter.isHallucination(text, peakLevel: 0.15),
                           "\(text) 在正常说话的音频上是真话")
        }
    }
}
