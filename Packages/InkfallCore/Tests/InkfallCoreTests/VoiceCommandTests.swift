import XCTest
@testable import InkfallCore

/// 关键词匹配与模板展开。
///
/// 这一层是「误触发一条任意 shell 命令」与「什么都没发生」之间的全部距离，
/// 所以每条归一化规则都要钉死。
final class VoiceCommandTests: XCTestCase {

    private func remove(_ text: String, _ keyword: String,
                        _ position: KeywordPosition = .anywhere) -> String? {
        VoiceCommandMatcher.removeKeyword(from: text, keyword: keyword, position: position)
    }

    // MARK: - `{text}` = 整句话减去关键词

    func testKeywordAtStartLeavesTheRest() {
        XCTAssertEqual(remove("克劳德，帮我解决这个 issue", "克劳德"), "帮我解决这个 issue")
    }

    func testKeywordAtEndLeavesTheFront() {
        XCTAssertEqual(remove("今天天气怎么样，小明", "小明"), "今天天气怎么样")
    }

    /// 两侧都有内容时都要留下来，用关键词**后面**那个分隔符重新连接。
    func testKeywordInTheMiddleKeepsBothSides() {
        XCTAssertEqual(remove("我想听歌，小明，帮我找找七里香", "小明"),
                       "我想听歌，帮我找找七里香")
    }

    /// 后面没有分隔符时回落到前面那个。
    func testJoinerFallsBackToTheOneBeforeTheKeyword() {
        XCTAssertEqual(remove("我想听歌；小明 帮我找找七里香", "小明"),
                       "我想听歌；帮我找找七里香")
    }

    /// 两侧都没有分隔符时用「，」。
    func testJoinerFallsBackToIdeographicComma() {
        XCTAssertEqual(remove("我想听歌 小明 帮我找找七里香", "小明"),
                       "我想听歌，帮我找找七里香")
    }

    // MARK: - 归一化

    /// ASR 爱在汉字之间插空格（含全角空格），「克 劳 德」必须也匹配得上。
    func testWhitespaceInsideTheKeywordIsIgnored() {
        XCTAssertEqual(remove("克 劳 德，你好", "克劳德"), "你好")
        XCTAssertEqual(remove("克\u{3000}劳德，你好", "克劳德"), "你好")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(remove("CLAUDE, fix this", "claude"), "fix this")
    }

    /// 设置里敲的关键词自己带空格也要能用。
    func testKeywordOwnWhitespaceIsIgnored() {
        XCTAssertEqual(remove("克劳德，你好", "克 劳 德"), "你好")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(remove("今天天气怎么样", "克劳德"))
        XCTAssertNil(remove("", "克劳德"))
        XCTAssertNil(remove("克劳德", ""))
    }

    /// 只有关键词时 `{text}` 是空串，**不是** nil —— 它仍然是一次命中。
    func testKeywordAloneMatchesWithEmptyText() {
        XCTAssertEqual(remove("克劳德", "克劳德"), "")
        XCTAssertEqual(remove("克劳德。", "克劳德"), "")
    }

    // MARK: - 位置约束

    func testStartOnlyRejectsKeywordInTheMiddle() {
        XCTAssertEqual(remove("小明，帮我找歌", "小明", .start), "帮我找歌")
        XCTAssertNil(remove("我想听歌，小明", "小明", .start))
    }

    func testEndOnlyRejectsKeywordAtTheStart() {
        XCTAssertEqual(remove("我想听歌，小明", "小明", .end), "我想听歌")
        XCTAssertNil(remove("小明，帮我找歌", "小明", .end))
    }

    func testStartOrEndAcceptsBothEdgesButNotTheMiddle() {
        XCTAssertEqual(remove("小明，帮我找歌", "小明", .startOrEnd), "帮我找歌")
        XCTAssertEqual(remove("帮我找歌，小明", "小明", .startOrEnd), "帮我找歌")
        XCTAssertNil(remove("帮我，小明，找歌", "小明", .startOrEnd))
    }

    /// 位置不允许时要继续往后扫，而不是就此放弃 —— 同一个词可能出现两次。
    func testScanContinuesToALaterOccurrenceThatSatisfiesThePosition() {
        XCTAssertEqual(remove("小明说，帮我找歌，小明", "小明", .end), "小明说，帮我找歌")
    }

    // MARK: - 模板展开与转义

    func testTemplateSubstitutesAllPlaceholderSpellings() {
        let command = VoiceCommand(
            keyword: "克劳德",
            commandTemplate: "claude \"{text}|{selection}|{selected text}|{selected_text}|{clipboard}\"")
        let shell = command.shellCommand(spoken: "甲", selection: "乙", clipboard: "丙")
        XCTAssertEqual(shell, "claude \"甲|乙|乙|乙|丙\"")
    }

    /// 双引号上下文：`\ " $ \`` 前面加反斜杠，`\r` 删掉，`\n` 变空格。
    func testEscapingForDoubleQuotedShellContext() {
        XCTAssertEqual(VoiceCommand.escapeForDoubleQuotes(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(VoiceCommand.escapeForDoubleQuotes(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(VoiceCommand.escapeForDoubleQuotes("a$b`c"), "a\\$b\\`c")
        // ⚠️ CRLF：Swift 的 Character 会把 "\r\n" 当成**一个**字形簇，
        // 按 Character 匹配就两条分支都落空，换行原样进脚本 —— 命令被截成两行。
        XCTAssertEqual(VoiceCommand.escapeForDoubleQuotes("a\r\nb"), "a b")
        XCTAssertEqual(VoiceCommand.escapeForDoubleQuotes("a\nb\rc"), "a bc")
    }

    /// 一次命令注入的形状：选区里带引号不能把命令截断成两条。
    func testSelectionWithQuotesCannotBreakOutOfTheQuotedArgument() {
        let command = VoiceCommand(keyword: "克劳德", commandTemplate: "claude \"{selection}\"")
        let shell = command.shellCommand(spoken: "", selection: "\"; rm -rf /; echo \"",
                                         clipboard: "")
        XCTAssertEqual(shell, #"claude "\"; rm -rf /; echo \"""#)
        // 判据不是「不含引号」——模板自己就带引号。判据是**没有一个裸引号**：
        // 除了模板那两个，每个 `"` 前面都必须有反斜杠。
        let scalars = Array(shell.unicodeScalars)
        let bare = scalars.indices.filter {
            scalars[$0] == "\"" && ($0 == 0 || scalars[$0 - 1] != "\\")
        }
        XCTAssertEqual(bare.count, 2, "模板自己的一对引号之外不该有裸引号")
    }

    // MARK: - 设置层的两道门

    private func settings(_ commands: [VoiceCommand], enabled: Bool) -> AppSettings {
        var s = AppSettings()
        s.voiceCommandsEnabled = enabled
        s.voiceCommands = commands
        return s
    }

    func testMatchingIsOffWhenTheFeatureIsDisabled() {
        let s = settings([.defaultClaude], enabled: false)
        XCTAssertNil(s.matchVoiceCommand("克劳德，你好"))
    }

    func testDisabledOrEmptyCommandsAreSkipped() {
        var disabled = VoiceCommand.defaultClaude
        disabled.enabled = false
        let blank = VoiceCommand(keyword: "  ", commandTemplate: "echo hi")
        let noTemplate = VoiceCommand(keyword: "甲", commandTemplate: "  ")
        let good = VoiceCommand(keyword: "乙", commandTemplate: "echo {text}")
        let s = settings([disabled, blank, noTemplate, good], enabled: true)
        XCTAssertNil(s.matchVoiceCommand("克劳德，你好"))
        XCTAssertNil(s.matchVoiceCommand("甲，你好"))
        XCTAssertEqual(s.matchVoiceCommand("乙，你好")?.spoken, "你好")
    }

    func testFirstMatchingCommandWins() {
        let first = VoiceCommand(keyword: "甲", commandTemplate: "echo 1")
        let second = VoiceCommand(keyword: "甲", commandTemplate: "echo 2")
        let s = settings([first, second], enabled: true)
        XCTAssertEqual(s.matchVoiceCommand("甲，你好")?.command.commandTemplate, "echo 1")
    }

    // MARK: - 容错解码

    /// 老配置没有 `continuousConversation` 之类的新字段，不能因此整表丢掉。
    func testDecodingToleratesMissingAndBrokenFields() throws {
        let json = """
        [{"keyword":"克劳德","commandTemplate":"claude \\"{text}\\"","terminal":"iterm",
          "enabled":true,"keywordPosition":"nonsense"}]
        """
        let commands = try JSONDecoder().decode([VoiceCommand].self, from: Data(json.utf8))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].keyword, "克劳德")
        XCTAssertEqual(commands[0].terminal, .iterm)
        // 认不出来的位置回落成默认的 anywhere，其余字段照常。
        XCTAssertEqual(commands[0].keywordPosition, .anywhere)
        XCTAssertFalse(commands[0].continuousConversation)
    }

    /// 「新标签页」必须激活终端，所以它和「保持焦点」互斥；Ghostty 根本开不了标签。
    func testSanitizeResolvesTheNewTabConflicts() {
        var s = AppSettings()
        s.voiceCommands = [
            VoiceCommand(keyword: "甲", commandTemplate: "echo", terminal: .terminal,
                         keepFocus: true, openInNewTab: true),
            VoiceCommand(keyword: "乙", commandTemplate: "echo", terminal: .ghostty,
                         keepFocus: true, openInNewTab: true),
        ]
        s.sanitize()
        XCTAssertTrue(s.voiceCommands[0].openInNewTab)
        XCTAssertFalse(s.voiceCommands[0].keepFocus)
        XCTAssertFalse(s.voiceCommands[1].openInNewTab)
        XCTAssertTrue(s.voiceCommands[1].keepFocus)
    }
}
