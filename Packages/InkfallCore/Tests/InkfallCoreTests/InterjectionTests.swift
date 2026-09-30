import XCTest
@testable import InkfallCore

// 插话纠错不碰网络的那一半：Jev 门的请求/解析、核对回答的解析、插不插的策略。
// 发请求那一层在 App（`InterjectionProbe`），靠 `--interject-test` / `--interject-eval` 真机验证。

final class InterjectionAPITests: XCTestCase {

    func testGateBodyAsksBothQuestionsInOneRequest() throws {
        let data = try XCTUnwrap(InterjectionAPI.gateBody(previous: ["今天去超市"], segment: "苹果是蔬菜"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "jev-latest")
        XCTAssertEqual(root["state"] as? [String: String], ["previous": "今天去超市", "segment": "苹果是蔬菜"])
        let questions = try XCTUnwrap(root["questions"] as? [String: [String: String]])
        XCTAssertEqual(Set(questions.keys), ["complete", "claim", "task", "question", "simple", "complex"])
        XCTAssertEqual(questions["complete"]?["instructions"], InterjectionAPI.completeQuestion)
        XCTAssertEqual(questions["claim"]?["type"], "noul")
    }

    func testParseGateAndThresholds() throws {
        let gate = try InterjectionAPI.parseGate(Data(
            #"{"answers":{"complete":{"noul":0.8},"claim":{"noul":0.9},"task":{"noul":0.1},"question":{"noul":0.2},"simple":{"noul":0.3},"complex":{"noul":0.4}}}"#.utf8))
        XCTAssertEqual(gate, .init(complete: 0.8, claim: 0.9, task: 0.1, question: 0.2, simple: 0.3, complex: 0.4))
        XCTAssertTrue(gate.passes)
        XCTAssertFalse(InterjectionAPI.Gate(complete: 0.29, claim: 0.9).passes)  // 没说完
        XCTAssertFalse(InterjectionAPI.Gate(complete: 0.9, claim: 0.49).passes)  // 没有事实断言
        XCTAssertThrowsError(try InterjectionAPI.parseGate(Data(#"{"answers":{"complete":{"noul":0.8}}}"#.utf8)))
    }

    func testRoute() {
        typealias G = InterjectionAPI.Gate
        // 手试的真实分数：清楚的任务 → agent，大而不清 → 起票面板
        XCTAssertEqual(G(complete: 0.9, claim: 0.1, task: 0.94, question: 0.03, simple: 0.18, complex: 0.17).route(checkComplete: true), .agent)
        XCTAssertEqual(G(complete: 0.9, claim: 0.1, task: 0.95, question: 0.02, simple: 0.28, complex: 0.93).route(checkComplete: true), .ticket)
        // 简单问题 → 当场回答；要查东西的问题 → agent
        XCTAssertEqual(G(complete: 0.9, claim: 0.1, task: 0.02, question: 0.96, simple: 0.98, complex: 0.03).route(checkComplete: true), .answer)
        XCTAssertEqual(G(complete: 0.9, claim: 0.1, task: 0.02, question: 0.96, simple: 0.04, complex: 0.11).route(checkComplete: true), .agent)
        XCTAssertEqual(G(complete: 0.9, claim: 0.9, task: 0.02, question: 0.04).route(checkComplete: true), .check)
        XCTAssertEqual(G(complete: 0.9, claim: 0.1, task: 0.1, question: 0.28).route(checkComplete: true), .none)
        // 两项都高：取高的
        XCTAssertEqual(G(complete: 0.9, claim: 0, task: 0.7, question: 0.9, simple: 0.9).route(checkComplete: true), .answer)
        // 没说完：切换录音的段才管；按住说话松手就算说完
        XCTAssertEqual(G(complete: 0.2, claim: 0, task: 0, question: 0.9, simple: 0.9).route(checkComplete: true), .incomplete)
        XCTAssertEqual(G(complete: 0.2, claim: 0, task: 0, question: 0.9, simple: 0.9).route(checkComplete: false), .answer)
    }

    func testCleanAnswerForSpeech() {
        XCTAssertEqual(InterjectionAPI.cleanAnswer("**东京**。\n- 人口约 1400 万"), "东京。 人口约 1400 万")
    }

    func testCheckInput() {
        XCTAssertEqual(InterjectionAPI.checkInput(previous: [], segment: "苹果是蔬菜"),
                       "previous:\n(none)\n\nsegment:\n苹果是蔬菜")
    }

    func testParseCheckToleratesFencesAndChatter() throws {
        let text = """
        好的：
        ```json
        {"wrong": true, "kind": "clear_error", "confidence": 0.95, "correction": " 苹果是水果 ", "detail": "苹果是蔷薇科植物的果实"}
        ```
        """
        XCTAssertEqual(try InterjectionAPI.parseCheck(text),
                       .init(wrong: true, kind: .clearError, confidence: 0.95, correction: "苹果是水果", detail: "苹果是蔷薇科植物的果实"))
    }

    func testSpeechLanguage() {
        XCTAssertEqual(InterjectionAPI.speechLanguage(for: "苹果是水果"), "zh-CN")
        XCTAssertEqual(InterjectionAPI.speechLanguage(for: "富士山は本州にある"), "ja-JP")
        XCTAssertEqual(InterjectionAPI.speechLanguage(for: "Python 由 Guido 创建"), "zh-CN")
        XCTAssertEqual(InterjectionAPI.speechLanguage(for: "Light is faster than sound"), "en-US")
    }

    func testParseCheckUnknownKindIsNotClaim() throws {
        let check = try InterjectionAPI.parseCheck(#"{"wrong": true, "kind": "maybe", "confidence": 1.4}"#)
        XCTAssertEqual(check.kind, .notClaim)
        XCTAssertEqual(check.confidence, 1)
        XCTAssertEqual(check.correction, "")
        XCTAssertThrowsError(try InterjectionAPI.parseCheck("不是 JSON"))
    }
}

final class InterjectionPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func wrong(_ correction: String = "苹果是水果", kind: InterjectionAPI.Kind = .clearError,
                       confidence: Double = 0.95) -> InterjectionAPI.Check {
        .init(wrong: true, kind: kind, confidence: confidence, correction: correction, detail: "")
    }

    func testShowsClearConfidentError() {
        var policy = InterjectionPolicy()
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: [], now: t0), .show(correction: "苹果是水果"))
    }

    func testDropsWhatIsNotAClearConfidentError() {
        var policy = InterjectionPolicy()
        let notWrong = InterjectionAPI.Check(wrong: false, kind: .correct, confidence: 0.9, correction: "", detail: "")
        XCTAssertEqual(policy.decide(notWrong, delay: 1, laterSegments: [], now: t0), .drop(.notWrong))
        XCTAssertEqual(policy.decide(wrong(kind: .disputed), delay: 1, laterSegments: [], now: t0), .drop(.notClearError))
        XCTAssertEqual(policy.decide(wrong(confidence: 0.79), delay: 1, laterSegments: [], now: t0), .drop(.lowConfidence))
        XCTAssertEqual(policy.decide(wrong(" "), delay: 1, laterSegments: [], now: t0), .drop(.emptyCorrection))
    }

    func testStaleAndSelfCorrected() {
        var policy = InterjectionPolicy()
        XCTAssertEqual(policy.decide(wrong(), delay: 5.1, laterSegments: [], now: t0), .drop(.stale))
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: ["哦不对，是水果"], now: t0), .drop(.selfCorrected))
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: ["No wait, it's a fruit"], now: t0), .drop(.selfCorrected))
        // 前面几次都没插，所以冷却没开始
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: ["然后我们去买了香蕉"], now: t0), .show(correction: "苹果是水果"))
    }

    func testSelfCorrectedWithinSegment() {
        var policy = InterjectionPolicy()
        XCTAssertEqual(policy.decide(wrong("水100度沸腾"), segment: "水50度就开，说错了，100度", delay: 1, laterSegments: [], now: t0),
                       .drop(.selfCorrected))
        // 「不是」只在后面的话里算改口，同一段里太常见
        XCTAssertEqual(policy.decide(wrong("鲸鱼是哺乳动物"), segment: "鲸鱼不是哺乳动物", delay: 1, laterSegments: [], now: t0),
                       .show(correction: "鲸鱼是哺乳动物"))
    }

    func testCooldownAndDuplicate() {
        var policy = InterjectionPolicy()
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: [], now: t0), .show(correction: "苹果是水果"))
        XCTAssertEqual(policy.decide(wrong("水100度沸腾"), delay: 1, laterSegments: [], now: t0.addingTimeInterval(3)), .drop(.cooldown))
        XCTAssertEqual(policy.decide(wrong(), delay: 1, laterSegments: [], now: t0.addingTimeInterval(600)), .drop(.duplicate))
        XCTAssertEqual(policy.decide(wrong("水100度沸腾"), delay: 1, laterSegments: [], now: t0.addingTimeInterval(600)),
                       .show(correction: "水100度沸腾"))
    }
}
