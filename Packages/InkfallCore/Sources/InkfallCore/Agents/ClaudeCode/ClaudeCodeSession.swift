import Foundation

/// 一条语音命令由谁来执行。
public enum VoiceCommandRunner: String, Codable, Sendable, CaseIterable {
    /// 开一个终端窗口跑一行 shell（原样保留的老路）。
    case terminal
    /// 后台跑 `claude -p`，并且**持续对话** —— 同一个关键词的后续几句
    /// 用 `--resume` 接回同一场会话。
    case claudeCode

    public var label: String {
        switch self {
        case .terminal: return "终端命令"
        case .claudeCode: return "Claude Code"
        }
    }
}

/// `claude -p` 一轮的全部输入。
///
/// 会话延续靠**我们自己生成的 UUID**：第一轮 `--session-id <uuid>` 把它按在
/// 那场会话上，之后 `--resume <uuid>`。这样不必从输出里刨 id ——
/// 第一轮的回答还没写完，我们就已经知道下一轮该接哪儿了。
public struct ClaudeCodeTurn: Sendable, Equatable {
    public var sessionID: String
    public var prompt: String
    /// 不是第一轮。
    public var resuming: Bool
    /// `--dangerously-skip-permissions`。**默认关**：语音是会误触的输入方式，
    /// 而这个开关等于把「改文件、跑命令」的确认全免掉。
    public var skipPermissions: Bool
    /// 免确认放行的工具。
    ///
    /// `-p` 是非交互的：需要确认的工具**弹不出确认框，直接被拒**，而模型只会
    /// 回一句「我没拿到权限」—— 用户看起来就像助手没有联网能力。所以要联网
    /// 查东西就必须显式放行。`skipPermissions` 开着时不用管（那是全免）。
    public var allowedTools: [String]
    /// 命令跑在哪个目录。空 = `$HOME`。
    public var workingDirectory: String
    public var outputPath: String
    public var errorPath: String
    /// 退出码。**总会**写出来 —— 它是「这一轮结束了没有」的唯一可靠信号，
    /// 光等 JSON 的话 claude 崩掉时会等到超时。
    public var statusPath: String
    public var claudePath: String

    public init(sessionID: String, prompt: String, resuming: Bool,
                skipPermissions: Bool = false, allowedTools: [String] = [],
                workingDirectory: String = "",
                outputPath: String, errorPath: String, statusPath: String,
                claudePath: String = "claude") {
        self.sessionID = sessionID
        self.prompt = prompt
        self.resuming = resuming
        self.skipPermissions = skipPermissions
        self.allowedTools = allowedTools
        self.workingDirectory = workingDirectory
        self.outputPath = outputPath
        self.errorPath = errorPath
        self.statusPath = statusPath
        self.claudePath = claudePath
    }
}

/// `claude -p --output-format json` 的回复。
public struct ClaudeCodeReply: Sendable, Equatable {
    public var text: String
    public var sessionID: String?
    public var isError: Bool
    public var durationMs: Int?
    public var costUSD: Double?

    public init(text: String, sessionID: String? = nil, isError: Bool = false,
                durationMs: Int? = nil, costUSD: Double? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.isError = isError
        self.durationMs = durationMs
        self.costUSD = costUSD
    }
}

public enum ClaudeCode {

    /// tmux 会话名。所有轮次都开在同一个会话里，`tmux attach -t inkfall`
    /// 就能看到整段对话 —— 这正是用 tmux 而不是裸后台进程的理由。
    public static let tmuxSession = "inkfall"

    /// 一轮最多等多久。带工具调用的回答几十秒是常事。
    public static let turnTimeoutSeconds: Double = 180

    /// 交给 `claude` 的参数。
    public static func arguments(for turn: ClaudeCodeTurn) -> [String] {
        var arguments = ["-p"]
        // 第一轮把 id 按上去，之后按同一个 id 接回来。
        arguments += turn.resuming ? ["--resume", turn.sessionID]
                                   : ["--session-id", turn.sessionID]
        if turn.skipPermissions {
            arguments.append("--dangerously-skip-permissions")
        } else if !turn.allowedTools.isEmpty {
            // ⚠️ 逗号连成**一个** argv。`--allowed-tools` 是变长参数，
            // 拆成多个会有把后面的提示词一起吞进去的风险。
            arguments += ["--allowed-tools", turn.allowedTools.joined(separator: ",")]
        }
        arguments += ["--output-format", "json", turn.prompt]
        return arguments
    }

    /// 只读的联网工具。
    ///
    /// 「查一下今天的股价」这类问题没有它就答不了 —— 而它既不改文件也不跑命令，
    /// 和 `--dangerously-skip-permissions` 完全不是一个风险量级。
    public static let webTools = ["WebSearch", "WebFetch"]

    /// 一轮的 zsh 脚本。
    ///
    /// ⚠️ 必须自己铺 PATH。App 是从 Finder / `open` 起来的，拿到的是一个
    /// 极简 PATH，而 tmux 服务器继承的又是它 —— 脚本里直接写 `claude`
    /// 会是「command not found」，而且**只在真机上复现**（终端里跑一切正常）。
    public static func script(for turn: ClaudeCodeTurn) -> String {
        let quote = VoiceCommand.escapeForDoubleQuotes
        let workdir = turn.workingDirectory.trimmingCharacters(in: .whitespaces)
        let cd = workdir.isEmpty ? "cd \"$HOME\""
                                 : "cd \"\(quote(workdir))\" 2>/dev/null || cd \"$HOME\""
        let claudeArguments = arguments(for: turn)
            .map { "\"\(quote($0))\"" }
            .joined(separator: " ")
        // 头一行把这一轮问的话打在 pane 上 —— attach 上去看到的才是一段对话，
        // 而不是一堆无从分辨的 JSON。
        return """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.claude/local:$HOME/.local/bin:$PATH"
        \(cd)
        print -r -- "▸ \(quote(turn.prompt))"
        "\(quote(turn.claudePath))" \(claudeArguments) > "\(quote(turn.outputPath))" 2> "\(quote(turn.errorPath))"
        printf '%s' $? > "\(quote(turn.statusPath))"
        /usr/bin/python3 -c 'import json,sys
        try: print(json.load(open(sys.argv[1])).get("result", ""))
        except Exception as error: print("（没有可读的回答）", error)' "\(quote(turn.outputPath))" 2>/dev/null || cat "\(quote(turn.errorPath))"

        """
    }

    /// 一轮 = tmux 里的一个窗口，窗口**直接跑脚本**。
    ///
    /// ⚠️ 刻意不走「常驻 shell + send-keys」那条更像 tmux 惯用法的路：
    /// 那样要等用户的交互式 shell 先到提示符，而那是**没有上界**的等待 ——
    /// 本机的 zshrc 只有几行（source 了一下 gcloud 的 completion）就要好几秒，
    /// 提示符出现之前敲进去的键会被 tty 回显在屏幕上、再被 ZLE 初始化丢掉：
    /// 命令躺在 pane 里，回车没反应，看起来像 tmux 坏了（实测踩过）。
    /// 直接把脚本交给窗口就没有这层时序依赖。
    public static func tmuxCreateSession(window: String, scriptPath: String) -> [String] {
        ["new-session", "-d", "-s", tmuxSession, "-n", window, "zsh \(scriptPath)"]
    }

    public static func tmuxCreateWindow(window: String, scriptPath: String) -> [String] {
        ["new-window", "-d", "-t", tmuxSession, "-n", window, "zsh \(scriptPath)"]
    }

    /// 跑完的 pane 留在那儿 —— 那就是这场对话的存档，也是会话不会因为
    /// 「最后一个窗口退出」而整个消失的原因。
    ///
    /// ⚠️ 必须**按窗口**设。`remain-on-exit` 是窗口选项，全局设会波及用户
    /// 自己在用的 tmux 窗口。
    public static func tmuxRemainOnExit(window: String) -> [String] {
        ["set-option", "-w", "-t", "\(tmuxSession):\(window)", "remain-on-exit", "on"]
    }

    /// 窗口名：只留 ASCII 字母数字，再加轮次 —— tmux 不吃中文与标点。
    public static func windowName(keyword: String, turn: Int) -> String {
        // ⚠️ 只留 **ASCII** 字母数字。`CharacterSet.alphanumerics` 是认汉字的
        // （它们也是字母），而关键词多半就是中文 —— 那样过滤等于没过滤。
        let cleaned = String(keyword.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let base = cleaned.isEmpty ? "ask" : String(cleaned.prefix(12))
        return "\(base)-\(turn)"
    }

    public static func parse(_ json: String) -> ClaudeCodeReply? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // `result` 缺席时回落到 stop_reason 之类的线索，但至少不能假装成功。
        let text = (object["result"] as? String) ?? ""
        return ClaudeCodeReply(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionID: object["session_id"] as? String,
            isError: (object["is_error"] as? Bool) ?? false,
            durationMs: (object["duration_ms"] as? NSNumber)?.intValue
                ?? (object["duration_api_ms"] as? NSNumber)?.intValue,
            costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    /// 刘海上那一行。回答可能很长，而刘海只有一行的位置。
    public static func answerLine(_ text: String, limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
