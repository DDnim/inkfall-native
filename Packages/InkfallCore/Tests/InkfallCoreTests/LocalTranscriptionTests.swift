import XCTest
@testable import InkfallCore

final class HallucinationFilterTests: XCTestCase {

    func testKnownSubtitleOutrosAreDropped() {
        // Whisper 在静音上吐字幕组片尾是最常见的失效模式。
        for phrase in ["字幕由Amara.org社群提供",
                       "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目",
                       "Thanks for watching!",
                       "ご視聴ありがとうございました",
                       "谢谢观看。"] {
            XCTAssertTrue(HallucinationFilter.isHallucination(phrase), phrase)
        }
    }

    func testNormalSpeechSurvives() {
        for text in ["今天下午三点开会，讨论一下落音的本地转写功能",
                     "帮我把这段翻译成英文",
                     "好的",
                     "Thanks for watching the demo, it was really useful",
                     "谢谢观看，另外记得把报告发我"] {
            XCTAssertFalse(HallucinationFilter.isHallucination(text), text)
        }
    }

    func testEmptyAndPunctuationOnlyAreDropped() {
        for text in ["", "   ", "。", "……", "、。，", "♪♪♪", "...", "\n\t"] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text), "「\(text)」")
        }
    }

    func testDegenerateRepetitionIsDropped() {
        // 解码陷进循环 —— 整段被同一个片段铺满。
        XCTAssertTrue(HallucinationFilter.isHallucination(
            String(repeating: "好的", count: 20)))
        XCTAssertTrue(HallucinationFilter.isHallucination(
            String(repeating: "thank you ", count: 12)))
    }

    func testOrdinarySpokenRepetitionSurvives() {
        // 真人确实会重复，但达不到「整段被铺满」的量级。
        XCTAssertFalse(HallucinationFilter.isHallucination("对对对，就是这个意思，你说得没错"))
        XCTAssertFalse(HallucinationFilter.isHallucination("好的好的，我马上去办这件事情"))
    }

    func testFilterNeverEditsInsideASentence() {
        // 只整条丢弃，绝不做子串删除 —— 抠掉一半比留着幻觉更糟。
        let text = "会议纪要发我一下，谢谢观看"
        XCTAssertFalse(HallucinationFilter.isHallucination(text))
    }

    func testNormalizationIgnoresCaseAndPunctuation() {
        XCTAssertEqual(HallucinationFilter.normalize("Thanks, for watching!"),
                       HallucinationFilter.normalize("thanksforwatching"))
    }
}

final class TranscriptionLanguagePolicyTests: XCTestCase {

    private func policy(_ mode: TranscriptionLanguageMode,
                        fixed: TranscriptionLanguage = .zh,
                        preferred: [TranscriptionLanguage] = [.zh, .en, .ja])
        -> TranscriptionLanguagePolicy {
        TranscriptionLanguagePolicy(mode: mode, fixed: fixed, preferred: preferred)
    }

    func testFixedModeAlwaysSendsTheFixedCode() {
        let p = policy(.fixed, fixed: .ja)
        XCTAssertEqual(p.requested(), "ja")
        // 已锁定的语言不该盖过用户明确固定的那个。
        XCTAssertEqual(p.requested(locked: .en), "ja")
    }

    func testOverrideBeatsEverything() {
        XCTAssertEqual(policy(.fixed, fixed: .zh).requested(override: .en), "en")
        XCTAssertEqual(policy(.auto).requested(override: .ja, locked: .zh), "ja")
    }

    func testAutoModeSendsNothingUntilLocked() {
        let p = policy(.auto)
        XCTAssertNil(p.requested(), "第一段必须让模型自己检测")
        XCTAssertEqual(p.requested(locked: .zh), "zh", "之后跟着会话锁走")
    }

    func testLockingRules() {
        // 固定模式没有可锁的东西。
        XCTAssertFalse(policy(.fixed).shouldLock(detected: .en, locked: nil))
        // 自动模式接受任何检测结果。
        XCTAssertTrue(policy(.auto).shouldLock(detected: .th, locked: nil))
        // 已经锁过就不再改 —— 一次会话只锁一次。
        XCTAssertFalse(policy(.auto).shouldLock(detected: .en, locked: .zh))
        // 检测失败不锁。
        XCTAssertFalse(policy(.auto).shouldLock(detected: nil, locked: nil))
    }

    func testPreferredModeRejectsLanguagesOutsideTheCandidateList() {
        let p = policy(.preferred, preferred: [.zh, .en])
        XCTAssertTrue(p.shouldLock(detected: .zh, locked: nil))
        // 一句噪声被判成越南语，不该把整场会锁到越南语上。
        XCTAssertFalse(p.shouldLock(detected: .vi, locked: nil))
    }

    func testEmptyPreferredListBehavesLikeAuto() {
        let p = policy(.preferred, preferred: [])
        XCTAssertTrue(p.shouldLock(detected: .vi, locked: nil))
    }

    func testPolicyReadsFromSettings() {
        var settings = AppSettings()
        settings.transcriptionLanguageMode = .fixed
        settings.fixedTranscriptionLanguage = .ja
        XCTAssertEqual(TranscriptionLanguagePolicy(settings: settings).requested(), "ja")
    }
}

final class VocabularyCorrectorTests: XCTestCase {

    func testFixesKnownMishearings() {
        let c = VocabularyCorrector(replacements: ["洛因": "落音"])
        XCTAssertEqual(c.apply("讨论一下洛因的本地转写功能"), "讨论一下落音的本地转写功能")
    }

    func testLeavesUnrelatedTextAlone() {
        let c = VocabularyCorrector(replacements: ["洛因": "落音"])
        // 不做模糊匹配 —— 「洛阳」绝不能被猜成「落音」。
        XCTAssertEqual(c.apply("我下周去洛阳出差"), "我下周去洛阳出差")
    }

    func testLongerRulesWinOverShorterOnes() {
        // 先换短规则会把长规则的匹配面咬掉一块。
        let c = VocabularyCorrector(replacements: ["洛因": "落音", "洛因笔记": "落音笔记本"])
        XCTAssertEqual(c.apply("打开洛因笔记"), "打开落音笔记本")
    }

    func testAsciiRulesAreCaseInsensitive() {
        let c = VocabularyCorrector(replacements: ["inkfull": "Inkfall"])
        XCTAssertEqual(c.apply("try InkFull today"), "try Inkfall today")
    }

    func testSelfReferentialAndEmptyRulesAreIgnored() {
        let c = VocabularyCorrector(replacements: ["": "x", "落音": "落音"])
        XCTAssertEqual(c.apply("落音很好用"), "落音很好用")
    }

    func testSanitizeDropsDegenerateRules() {
        var s = AppSettings()
        s.transcriptionReplacements = ["": "炸", " ": "空", "同": "同", "洛因": "落音"]
        s.sanitize()
        XCTAssertEqual(s.transcriptionReplacements, ["洛因": "落音"])
    }
}
