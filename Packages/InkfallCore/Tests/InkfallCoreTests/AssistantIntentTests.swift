import XCTest
@testable import InkfallCore

// 叫助手判定（Jev）不碰网络的那一半：三段式的边界、app_kind 对照表、请求体、响应解析。
// 真正发请求那一层在 App 里（`AssistantIntentProbe`），靠 `--intent-test` 真机验证。

final class AssistantIntentTests: XCTestCase {

    func testVerdictBoundaries() {
        XCTAssertEqual(AssistantIntentAPI.Verdict.decide(0.6), .call)
        XCTAssertEqual(AssistantIntentAPI.Verdict.decide(0.59), .ask)
        XCTAssertEqual(AssistantIntentAPI.Verdict.decide(0.4), .ask)
        XCTAssertEqual(AssistantIntentAPI.Verdict.decide(0.39), .text)
    }

    func testAppKind() {
        XCTAssertEqual(AssistantIntentAPI.appKind(bundleID: "com.tinyspeck.slackmacgap"), "chat with other people")
        XCTAssertEqual(AssistantIntentAPI.appKind(bundleID: "com.apple.Terminal"), "developer tool")
        XCTAssertEqual(AssistantIntentAPI.appKind(bundleID: "com.microsoft.VSCode"), "developer tool")
        // 前缀匹配只认整段：com.apple.mailx 不是 Mail
        XCTAssertEqual(AssistantIntentAPI.appKind(bundleID: "com.apple.mailx"), "unknown")
        XCTAssertEqual(AssistantIntentAPI.appKind(bundleID: nil), "unknown")
    }

    func testBodyCarriesAppKindAndVerbatimQuestion() throws {
        let data = try XCTUnwrap(AssistantIntentAPI.body(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", text: "帮我看一下这个 PR"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(root["state"] as? [String: String])
        XCTAssertEqual(state, ["app": "Slack", "app_kind": "chat with other people", "text": "帮我看一下这个 PR"])
        let q = try XCTUnwrap((root["questions"] as? [String: Any])?["assistant"] as? [String: String])
        XCTAssertEqual(q["type"], "noul")
        XCTAssertTrue(q["instructions"]!.hasSuffix("usually a commit message being dictated."))
    }

    func testParse() throws {
        let ok = Data(#"{"answers":{"assistant":{"noul":0.83}}}"#.utf8)
        XCTAssertEqual(try AssistantIntentAPI.parse(ok), 0.83, accuracy: 1e-9)
        XCTAssertThrowsError(try AssistantIntentAPI.parse(Data(#"{"answers":{}}"#.utf8)))
        XCTAssertThrowsError(try AssistantIntentAPI.parse(Data(#"{"answers":{"assistant":{"noul":1.5}}}"#.utf8)))
    }
}

final class KanbanHandoffTests: XCTestCase {

    func testConfigNeedsEnabledPortAndToken() {
        let ok = Data(#"{"mobileControl":{"enabled":true,"port":8765,"token":"abc"}}"#.utf8)
        XCTAssertEqual(KanbanHandoffAPI.config(fromPluginData: ok), .init(port: 8765, token: "abc"))
        XCTAssertNil(KanbanHandoffAPI.config(fromPluginData: Data(#"{"mobileControl":{"enabled":false,"port":8765,"token":"abc"}}"#.utf8)))
        XCTAssertNil(KanbanHandoffAPI.config(fromPluginData: Data(#"{"mobileControl":{"enabled":true,"port":8765,"token":""}}"#.utf8)))
        XCTAssertNil(KanbanHandoffAPI.config(fromPluginData: Data(#"{}"#.utf8)))
    }

    func testRequest() throws {
        let config = KanbanHandoffAPI.Config(port: 8765, token: "abc")
        XCTAssertEqual(KanbanHandoffAPI.endpoint(config).absoluteString, "http://127.0.0.1:8765/api/open-issue")
        XCTAssertEqual(KanbanHandoffAPI.headers(config)["Authorization"], "Bearer abc")
        let body = try XCTUnwrap(KanbanHandoffAPI.body(text: "总结一下这个网页"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"input":"总结一下这个网页"}"#)
    }

    func testParseOpened() {
        XCTAssertTrue(KanbanHandoffAPI.parseOpened(Data(#"{"opened":true}"#.utf8)))
        XCTAssertFalse(KanbanHandoffAPI.parseOpened(Data(#"{"error":"見つかりません"}"#.utf8)))
    }
}
