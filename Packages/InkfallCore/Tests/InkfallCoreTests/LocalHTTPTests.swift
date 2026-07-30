import XCTest
@testable import InkfallCore

/// 本地集成 API 的语法层。
///
/// 传输交给 Network.framework，但**解析必须能单测** —— 一个跑在真实端口上的
/// 框架反而没法测边界（半截请求、超大 header、缺 Content-Length）。
final class LocalHTTPTests: XCTestCase {

    private func parse(_ text: String) -> LocalHTTPParser.Outcome {
        LocalHTTPParser.parse(Data(text.utf8)).outcome
    }

    func testParsesMethodPathHeadersAndBody() {
        let raw = """
        POST /api/notes HTTP/1.1\r
        Host: 127.0.0.1:48765\r
        Authorization: Bearer abc123\r
        Content-Type: application/json\r
        Content-Length: 17\r
        \r
        {"text":"hello"}\n
        """
        guard case .request(let request) = parse(raw) else {
            return XCTFail("没解析出请求")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/notes")
        XCTAssertEqual(request.bearerToken, "abc123")
        XCTAssertEqual(request.body, "{\"text\":\"hello\"}\n")
        // header 名不区分大小写，客户端写法五花八门。
        XCTAssertEqual(request.headers["content-type"], "application/json")
    }

    func testBearerTokenParsingIsCaseInsensitiveAndRejectsOtherSchemes() {
        var request = LocalHTTPRequest(method: "GET", path: "/api/notes",
                                       headers: ["authorization": "bearer xyz"])
        XCTAssertEqual(request.bearerToken, "xyz")
        request.headers["authorization"] = "Basic xyz"
        XCTAssertNil(request.bearerToken)
        request.headers["authorization"] = "Bearer"
        XCTAssertNil(request.bearerToken)
    }

    /// 收到半截就要说「继续读」，绝不能拿残缺的 body 去改笔记。
    func testIncompleteRequestsAskForMore() {
        XCTAssertEqual(parse("GET /api/notes HTTP/1.1\r\nHost: x\r\n"), .incomplete)
        let truncated = "POST /api/notes HTTP/1.1\r\nContent-Length: 40\r\n\r\n{\"text\":\"甲\"}"
        XCTAssertEqual(parse(truncated), .incomplete)
    }

    func testConsumedLengthAllowsAFollowingRequest() {
        let raw = "GET /health HTTP/1.1\r\n\r\nGET /health HTTP/1.1\r\n\r\n"
        let (outcome, consumed) = LocalHTTPParser.parse(Data(raw.utf8))
        guard case .request = outcome else { return XCTFail("没解析出请求") }
        XCTAssertEqual(consumed, 24)
        let rest = Data(raw.utf8).dropFirst(consumed)
        guard case .request = LocalHTTPParser.parse(Data(rest)).outcome else {
            return XCTFail("第二条没解析出来")
        }
    }

    func testOversizedHeaderAndBodyAreRejectedNotBuffered() {
        let huge = String(repeating: "x", count: LocalHTTPParser.maxHeaderBytes + 10)
        XCTAssertEqual(parse("GET /a HTTP/1.1\r\nX: \(huge)"),
                       .failure(status: 431, message: "header too large"))
        let big = LocalHTTPParser.maxBodyBytes + 1
        XCTAssertEqual(parse("POST /a HTTP/1.1\r\nContent-Length: \(big)\r\n\r\n"),
                       .failure(status: 413, message: "body too large"))
    }

    func testQueryStringIsSplitAndPercentDecoded() {
        let (path, query) = LocalHTTPParser.splitTarget(
            "/debug/jarvis/match?text=%E5%85%8B%E5%8A%B3%E5%BE%B7%EF%BC%8C%E4%BD%A0%E5%A5%BD&delay=2&flag")
        XCTAssertEqual(path, "/debug/jarvis/match")
        XCTAssertEqual(query["text"], "克劳德，你好")
        XCTAssertEqual(query["delay"], "2")
        XCTAssertEqual(query["flag"], "")
        // 表单编码里 `+` 是空格。
        XCTAssertEqual(LocalHTTPParser.splitTarget("/x?a=b+c").query["a"], "b c")
    }

    // MARK: - 路由

    func testRoutesCoverTheFiveDocumentedOnes() {
        XCTAssertEqual(IntegrationRoute.match(method: "GET", path: "/api/notes"), .list)
        XCTAssertEqual(IntegrationRoute.match(method: "GET", path: "/api/notes/ABC"), .read("ABC"))
        XCTAssertEqual(IntegrationRoute.match(method: "POST", path: "/api/notes"), .create)
        XCTAssertEqual(IntegrationRoute.match(method: "PATCH", path: "/api/notes/ABC"),
                       .update("ABC"))
        XCTAssertEqual(IntegrationRoute.match(method: "DELETE", path: "/api/notes/ABC"),
                       .delete("ABC"))
        XCTAssertEqual(IntegrationRoute.match(method: "get", path: "/api/notes/"), .list)
    }

    func testUnknownRoutesAndMethodsDoNotMatch() {
        XCTAssertNil(IntegrationRoute.match(method: "GET", path: "/api/settings"))
        XCTAssertNil(IntegrationRoute.match(method: "PUT", path: "/api/notes/ABC"))
        XCTAssertNil(IntegrationRoute.match(method: "DELETE", path: "/api/notes"))
        XCTAssertNil(IntegrationRoute.match(method: "GET", path: "/debug/jarvis/state"))
    }

    // MARK: - token

    func testTokenComparisonRejectsWrongAndPartial() {
        let token = IntegrationToken.generate()
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(IntegrationToken.matches(token, token))
        XCTAssertFalse(IntegrationToken.matches(token, ""))
        XCTAssertFalse(IntegrationToken.matches(token, String(token.dropLast())))
        XCTAssertFalse(IntegrationToken.matches(token, String(token.dropLast()) + "0"))
        // 空 token 不能被空候选「匹配上」——否则文件还没生成时就是完全敞开的。
        XCTAssertFalse(IntegrationToken.matches("", ""))
        XCTAssertNotEqual(IntegrationToken.generate(), IntegrationToken.generate())
    }
}
