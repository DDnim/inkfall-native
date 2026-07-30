import XCTest
@testable import InkfallCore

/// `claude -p` 的参数、脚本与回复解析。
///
/// 会话延续靠**我们自己生成的 UUID**（第一轮 `--session-id`，之后 `--resume`），
/// 所以这里最要紧的是：同一个 id 两轮之间不许变形，提示词里的引号不许把
/// 脚本撑破。
final class ClaudeCodeTests: XCTestCase {

    private let sid = "da3b75dc-5b4a-45da-b857-26454af4ff61"

    private func turn(_ prompt: String, resuming: Bool = false,
                      skipPermissions: Bool = false,
                      workingDirectory: String = "") -> ClaudeCodeTurn {
        ClaudeCodeTurn(sessionID: sid, prompt: prompt, resuming: resuming,
                       skipPermissions: skipPermissions,
                       workingDirectory: workingDirectory,
                       outputPath: "/tmp/out.json", errorPath: "/tmp/err.log",
                       statusPath: "/tmp/status", claudePath: "/opt/homebrew/bin/claude")
    }

    // MARK: - 参数

    /// 第一轮把 id **按上去**，之后按同一个 id 接回来 —— 这是持续对话的全部机制。
    func testFirstTurnPinsTheSessionIdAndLaterTurnsResumeIt() {
        XCTAssertEqual(ClaudeCode.arguments(for: turn("你好")),
                       ["-p", "--session-id", sid, "--output-format", "json", "你好"])
        XCTAssertEqual(ClaudeCode.arguments(for: turn("接着说", resuming: true)),
                       ["-p", "--resume", sid, "--output-format", "json", "接着说"])
    }

    /// 跳过权限确认是**显式的**，默认不在参数里。
    func testSkipPermissionsIsOptOut() {
        XCTAssertFalse(ClaudeCode.arguments(for: turn("你好"))
            .contains("--dangerously-skip-permissions"))
        XCTAssertTrue(ClaudeCode.arguments(for: turn("你好", skipPermissions: true))
            .contains("--dangerously-skip-permissions"))
    }

    /// `-p` 是非交互的：要确认的工具弹不出确认框会被**直接拒掉**，模型只回
    /// 一句「我没拿到权限」——「查一下今天的股价」于是永远答不了。
    /// 放行只读的联网工具是这条路唯一的开关。
    func testWebToolsAreAllowedAsOneCommaJoinedArgument() {
        var web = turn("今天 4419 多少钱")
        web.allowedTools = ClaudeCode.webTools
        let arguments = ClaudeCode.arguments(for: web)
        guard let index = arguments.firstIndex(of: "--allowed-tools") else {
            return XCTFail("没有放行任何工具")
        }
        // ⚠️ 必须是**一个** argv：`--allowed-tools` 是变长参数，拆开有把后面的
        // 提示词一起吞进去的风险。
        XCTAssertEqual(arguments[index + 1], "WebSearch,WebFetch")
        XCTAssertEqual(arguments.last, "今天 4419 多少钱", "提示词必须还在最后一位")
    }

    /// 全免的时候不用再单独放行 —— 而且两个一起给只会让 argv 更难读。
    func testSkipPermissionsSupersedesTheAllowList() {
        var both = turn("你好", skipPermissions: true)
        both.allowedTools = ClaudeCode.webTools
        let arguments = ClaudeCode.arguments(for: both)
        XCTAssertTrue(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(arguments.contains("--allowed-tools"))
    }

    /// 联网默认**开**：不开的话助手只是一个记忆截止到训练日的盒子。
    /// 它只读不写，和「跳过权限确认」不是一个风险量级。
    func testWebToolsAreOnByDefaultButSkipPermissionsIsNot() {
        XCTAssertTrue(VoiceCommand().allowWebTools)
        XCTAssertTrue(VoiceCommand.defaultClaude.allowWebTools)
        XCTAssertFalse(VoiceCommand.defaultClaude.skipPermissions)
    }

    // MARK: - 脚本

    /// ⚠️ PATH 必须自己铺。App 从 Finder / `open` 起来时拿到的是极简 PATH，
    /// tmux 服务器继承的又是它 —— 直接写 `claude` 会是 command not found，
    /// 而且只在真机上复现（终端里跑一切正常）。
    func testScriptLaysItsOwnPath() {
        let script = ClaudeCode.script(for: turn("你好"))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(script.contains("export PATH="))
        XCTAssertTrue(script.contains("/opt/homebrew/bin"))
        XCTAssertTrue(script.contains(".claude/local"))
    }

    /// 退出码**总会**写出来 —— 它是「这一轮结束了没有」的唯一可靠信号。
    /// 只等 JSON 的话，claude 崩掉时会一路等到超时。
    func testScriptAlwaysWritesAStatusFile() {
        let script = ClaudeCode.script(for: turn("你好"))
        XCTAssertTrue(script.contains("printf '%s' $? > \"/tmp/status\""))
        XCTAssertTrue(script.contains("> \"/tmp/out.json\""))
        XCTAssertTrue(script.contains("2> \"/tmp/err.log\""))
    }

    func testScriptCdsToTheWorkingDirectoryAndFallsBackHome() {
        XCTAssertTrue(ClaudeCode.script(for: turn("你好")).contains("cd \"$HOME\""))
        let scoped = ClaudeCode.script(for: turn("你好", workingDirectory: "/Users/x/repo"))
        XCTAssertTrue(scoped.contains("cd \"/Users/x/repo\" 2>/dev/null || cd \"$HOME\""))
    }

    /// 提示词里带引号、反引号、`$` 不能把脚本撑破 —— 语音转写出来的文本
    /// 什么字符都可能有。
    func testPromptWithShellMetacharactersStaysInsideItsArgument() {
        let script = ClaudeCode.script(for: turn("帮我看看 \"$HOME/x\"；`ls` 是什么"))
        XCTAssertTrue(script.contains(#"\"\$HOME/x\""#))
        XCTAssertTrue(script.contains(#"\`ls\`"#))
        // 撑破的样子：出现一个前面没有反斜杠的裸引号后还跟着命令。
        XCTAssertFalse(script.contains("\"帮我看看 \""))
    }

    // MARK: - tmux

    /// 窗口**直接跑脚本**。
    ///
    /// ⚠️ 不走「常驻 shell + send-keys」：那样要等交互式 shell 先到提示符，
    /// 而那是**没有上界**的等待（source 一下 gcloud 的 completion 就要几秒）。
    /// 提示符出现之前敲进去的键会被 tty 回显、再被 ZLE 初始化丢掉 ——
    /// 命令躺在 pane 里，回车没反应（实测踩过）。
    func testTmuxRunsTheScriptDirectly() {
        XCTAssertEqual(ClaudeCode.tmuxCreateSession(window: "ke-1", scriptPath: "/tmp/a.command"),
                       ["new-session", "-d", "-s", "inkfall", "-n", "ke-1", "zsh /tmp/a.command"])
        XCTAssertEqual(ClaudeCode.tmuxCreateWindow(window: "ke-2", scriptPath: "/tmp/b.command"),
                       ["new-window", "-d", "-t", "inkfall", "-n", "ke-2", "zsh /tmp/b.command"])
    }

    /// `remain-on-exit` 必须**按窗口**设：它是窗口选项，全局设会波及用户
    /// 自己在用的 tmux 窗口。没有它，跑完的 pane 被销毁，最后一个窗口没了
    /// 会话也跟着没 —— attach 上去什么都看不到。
    func testRemainOnExitIsScopedToOurOwnWindow() {
        let arguments = ClaudeCode.tmuxRemainOnExit(window: "ke-1")
        XCTAssertEqual(arguments,
                       ["set-option", "-w", "-t", "inkfall:ke-1", "remain-on-exit", "on"])
        XCTAssertFalse(arguments.contains("-g"), "绝不能设成全局")
    }

    /// tmux 的窗口名不吃中文与标点，而关键词多半就是中文。
    func testWindowNamesAreSanitized() {
        XCTAssertEqual(ClaudeCode.windowName(keyword: "克劳德", turn: 3), "ask-3")
        XCTAssertEqual(ClaudeCode.windowName(keyword: "ask claude!", turn: 1), "askclaude-1")
        XCTAssertEqual(ClaudeCode.windowName(keyword: "", turn: 7), "ask-7")
    }

    // MARK: - 解析

    func testParsesTheJsonReply() {
        let json = """
        {"is_error":false,"duration_ms":2823,"session_id":"\(sid)",
         "total_cost_usd":0.0822,"result":"橘子"}
        """
        let reply = ClaudeCode.parse(json)
        XCTAssertEqual(reply?.text, "橘子")
        XCTAssertEqual(reply?.sessionID, sid)
        XCTAssertEqual(reply?.isError, false)
        XCTAssertEqual(reply?.durationMs, 2823)
        XCTAssertEqual(reply?.costUSD ?? 0, 0.0822, accuracy: 0.0001)
    }

    /// 出错的一轮不能被当成一句空回答放过去。
    func testErrorRepliesAreFlagged() {
        XCTAssertEqual(ClaudeCode.parse(#"{"is_error":true,"result":"额度用完了"}"#)?.isError,
                       true)
        XCTAssertNil(ClaudeCode.parse("这不是 JSON"))
        XCTAssertNil(ClaudeCode.parse(""))
        // 字段残缺时也要活着回来 —— 但 text 是空的，调用方看得出来。
        XCTAssertEqual(ClaudeCode.parse("{}")?.text, "")
    }

    func testAnswerLineIsTruncatedForTheNotch() {
        let long = String(repeating: "一", count: 80)
        XCTAssertEqual(ClaudeCode.answerLine(long).count, 61)
        XCTAssertEqual(ClaudeCode.answerLine("好\n的"), "好 的")
    }

    // MARK: - 提示词模板

    /// `claudeCode` 的模板是**提问模板**，不是 shell —— 引号和分行都是内容。
    func testPromptTemplateKeepsQuotesAndNewlines() {
        let command = VoiceCommand(keyword: "克劳德", commandTemplate: "{text}\n\n{selection}",
                                   runner: .claudeCode)
        let prompt = command.prompt(spoken: "他说 \"不行\"", selection: "let x = 1",
                                    clipboard: "")
        XCTAssertEqual(prompt, "他说 \"不行\"\n\nlet x = 1")
    }

    /// 占位符落空时不该留下一串空行。
    func testPromptCollapsesEmptyPlaceholders() {
        let command = VoiceCommand(keyword: "克劳德", commandTemplate: "{text}\n\n{selection}",
                                   runner: .claudeCode)
        XCTAssertEqual(command.prompt(spoken: "你好", selection: "", clipboard: ""), "你好")
        // 模板整个落空时回落到口述内容 —— 发一句空提示词只会浪费一轮。
        let selectionOnly = VoiceCommand(keyword: "克劳德", commandTemplate: "{selection}",
                                         runner: .claudeCode)
        XCTAssertEqual(selectionOnly.prompt(spoken: "解释一下", selection: "", clipboard: ""),
                       "解释一下")
    }

    /// 老配置里没有 `runner` 这个键，它们写的都是一行 shell。
    func testConfigsWithoutRunnerFallBackToTerminal() throws {
        let json = #"[{"keyword":"甲","commandTemplate":"echo hi","terminal":"terminal"}]"#
        let commands = try JSONDecoder().decode([VoiceCommand].self, from: Data(json.utf8))
        XCTAssertEqual(commands[0].runner, .terminal)
        XCTAssertFalse(commands[0].skipPermissions)
        XCTAssertEqual(commands[0].workingDirectory, "")
    }

    /// 内置示例就是这个功能本身：后台 claude + 持续对话。
    func testTheBuiltInExampleIsAClaudeCodeConversation() {
        XCTAssertEqual(VoiceCommand.defaultClaude.runner, .claudeCode)
        XCTAssertTrue(VoiceCommand.defaultClaude.continuousConversation)
        XCTAssertFalse(VoiceCommand.defaultClaude.skipPermissions)
    }
}
