import Foundation

/// 本机装着的「命令行编码助手」。
///
/// 目前只有 Claude Code 一个，但 gemini-cli / codex-cli 是同一类东西：
/// 一个非交互模式（`-p` 之类）、一段 system prompt、一段输入、
/// 一路 JSONL 流回来。所以这一层定的是**共同形状**，每个工具只补三件事：
///
/// 1. 可执行文件叫什么、可能装在哪儿（App 从 Finder 起来时 PATH 是空的）
/// 2. 一次「纯文本变换」的命令行怎么拼
/// 3. 流式输出的一行怎么解
///
/// 加一个工具 = 加一个 case + 一个 `Agents/<工具名>/` 目录，不动调用方。
public enum CLIAgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    // 未来：case geminiCLI / case codexCLI —— 各自在 Agents/ 下开一个目录，
    // 在下面四个 switch 里补一行。

    public var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        }
    }

    /// 可执行文件名。
    public var executable: String {
        switch self {
        case .claudeCode: return "claude"
        }
    }

    /// 除了常规的 homebrew / `/usr/bin` 之外还要找的地方（相对家目录）。
    public var extraSearchPaths: [String] {
        switch self {
        case .claudeCode: return [".claude/local/claude", ".local/bin/claude"]
        }
    }

    /// 这个工具认哪几档「思考力度」。加工是低难度高频的活儿，
    /// 第一档（`levels.first`）就是默认。
    public var effortLevels: [String] {
        switch self {
        case .claudeCode: return ["low", "medium", "high"]
        }
    }

    /// 一次纯文本变换的命令行。
    ///
    /// ⚠️ 每个工具都必须在这里**把上下文裁干净**（不加载项目记忆、skills、
    /// MCP、工具定义）。裸调 `claude -p` 实测一次口语清理 19 982 token，
    /// 裁完是 256 —— 这不是优化，是可用性问题。
    public func transformArguments(instructions: String, input: String,
                                   effort: String, model: String = "",
                                   streaming: Bool = true) -> [String] {
        switch self {
        case .claudeCode:
            return ClaudeCodeCLI.transformArguments(instructions: instructions, input: input,
                                                    effort: effort, model: model,
                                                    streaming: streaming)
        }
    }

    /// 解析流式输出的一行。
    public func parse(line: String) -> CLIAgentEvent {
        switch self {
        case .claudeCode: return ClaudeCodeCLI.parse(line: line)
        }
    }

    /// 一轮最多等多久。
    public var timeoutSeconds: Double {
        switch self {
        case .claudeCode: return ClaudeCodeCLI.timeoutSeconds
        }
    }
}

/// 流式输出里我们关心的三种东西。工具之间的 JSONL 格式不同，
/// 但归到这三类之后调用方就不必知道跑的是谁。
public enum CLIAgentEvent: Sendable, Equatable {
    /// 逐 token 吐出来的正文增量。
    case textDelta(String)
    /// 最后一行：完整结果与账单。
    case result(Result)
    /// 认不出来的行（init、status、工具事件…）—— 忽略，不是错误。
    case ignored

    public struct Result: Sendable, Equatable {
        public var text: String
        public var isError: Bool
        public var costUSD: Double?
        public var durationMs: Int?
        /// `api_error` 之类的分类，用来把「没登录」和「网络断了」说成两句话。
        public var errorKind: String?

        public init(text: String, isError: Bool, costUSD: Double? = nil,
                    durationMs: Int? = nil, errorKind: String? = nil) {
            self.text = text
            self.isError = isError
            self.costUSD = costUSD
            self.durationMs = durationMs
            self.errorKind = errorKind
        }
    }
}
