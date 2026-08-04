import Foundation

/// Claude Code 的 headless 模式（`claude -p`）作为加工引擎。
///
/// 不需要 OpenAI/Groq/Gemini 的 key，也**不需要 `ANTHROPIC_API_KEY`** ——
/// 用的是用户已经装好、已经登录的 Claude Code。
///
/// ⚠️ 但**必须显式把上下文裁干净**。裸的 `claude -p` 会加载和交互式会话
/// 一样的东西（CLAUDE.md、skills、hooks、auto memory、MCP、全套工具定义），
/// 本机实测一次两行的口语清理吃掉 **19 982 个 cache-creation token、$0.2006**。
/// 加上下面那几个开关之后是 **256 个 input token、$0.0027** —— 74 倍的差距，
/// 而且不必像 `--bare` 那样牺牲 OAuth（bare 会跳过登录态，反而要 API key）。
///
/// 共用形状（怎么找可执行文件、事件类型、超时语义）在 `CLIAgent.swift`；
/// 这里只有 Claude Code 自己的命令行与 JSONL 格式。
public enum ClaudeCodeCLI {

    /// 一轮加工最多等多久。加工是纯文本变换，没有工具调用，
    /// 比贾维斯那种带工具的轮次短得多。
    public static let timeoutSeconds: Double = 60

    /// 把上下文裁到只剩「这一次变换」所需的东西。
    ///
    /// 每一条都对应实测里的一大块 token，**少一条就多几千个**：
    /// - `--tools ""`：纯文本变换一个工具都用不到，工具定义却最占篇幅
    /// - `--disable-slash-commands`：不加载 skills
    /// - `--strict-mcp-config`：不带 `--mcp-config` 时等于关掉所有 MCP
    /// - `--setting-sources ""`：不读 user / project / local 设置，
    ///   于是 hooks、CLAUDE.md 自动发现、插件都不会进来
    static let leanContextFlags = [
        "--tools", "",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--setting-sources", "",
    ]

    /// 命令行。**纯函数**，这样参数拼错能被单测抓住而不是变成一次静默失败。
    ///
    /// - `--system-prompt` 而不是 `--append-system-prompt`：加工要的是一次
    ///   纯文本变换，Claude Code 默认那套「你是编码助手、你有这些工具」的
    ///   前言只会干扰它。整段替换掉，行为就和一次普通 API 调用一样。
    /// - `--effort`：加工是低难度高频的活儿，默认 `low`，别让它花 token 想。
    public static func transformArguments(instructions: String,
                                          input: String,
                                          effort: String,
                                          model: String = "",
                                          streaming: Bool = true) -> [String] {
        var arguments = ["-p", "--system-prompt", instructions, input]
        arguments += leanContextFlags
        let level = effort.trimmingCharacters(in: .whitespaces)
        if !level.isEmpty { arguments += ["--effort", level] }
        if !model.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--model", model]
        }
        if streaming {
            // 三个 flag 必须一起给：stream-json 只在 --verbose 下输出完整事件流，
            // 而**逐 token 的增量**要再加 --include-partial-messages。
            arguments += ["--output-format", "stream-json", "--verbose",
                          "--include-partial-messages"]
        } else {
            arguments += ["--output-format", "json"]
        }
        return arguments
    }

    /// 解析一行 JSONL。
    ///
    /// ⚠️ 只认 `event.delta.type == "text_delta"`，**不**去判外层的
    /// `type` 字段 —— 事件包装名在不同版本里变过，而 delta 的形状是稳定的。
    public static func parse(line: String) -> CLIAgentEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }

        if let event = object["event"] as? [String: Any],
           let delta = event["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return .textDelta(text)
        }

        guard object["type"] as? String == "result" else { return .ignored }
        return .result(.init(
            text: (object["result"] as? String) ?? "",
            // ⚠️ 认证失败那条线上 `subtype` 仍然是 `"success"`，
            // 只有 `is_error` 是 true。判 subtype 会把「没登录」当成成功。
            isError: (object["is_error"] as? Bool) ?? false,
            costUSD: object["total_cost_usd"] as? Double,
            durationMs: object["duration_ms"] as? Int,
            errorKind: object["terminal_reason"] as? String))
    }
}
