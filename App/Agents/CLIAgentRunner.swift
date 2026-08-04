import Foundation
import InkfallCore

/// 在本机找命令行工具。
///
/// ⚠️ App 是从 Finder / `open` 起来的，**PATH 里没有 homebrew**，也没有
/// `~/.claude/local`。所有外部命令都必须自己找绝对路径 —— 少一条搜索路径
/// 就等于「明明装了却说没装」。
enum CLIAgentLocator {

    static func locate(_ name: String, extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = extra + [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
            "\(home)/.claude/local/\(name)", "\(home)/.local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 某个助手装没装。
    static func path(for agent: CLIAgentKind) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return locate(agent.executable, extra: agent.extraSearchPaths.map { "\(home)/\($0)" })
    }
}

/// 跑一次「文本进、文本出」的 CLI 助手调用，流式读回来。
///
/// 这一层对具体是哪个工具是**无知的**：命令行怎么拼、JSONL 怎么解都在
/// `CLIAgentKind` 里。加 gemini-cli / codex-cli 时这个文件一行都不用改。
///
/// **不需要任何 API key** —— 用的是用户已经装好、已经登录的那个工具本身。
enum CLIAgentRunner {

    static func runTransform(
        agent: CLIAgentKind,
        executablePath: String,
        instructions: String,
        input: String,
        effort: String,
        model: String,
        onDelta: (@Sendable (String) -> Void)?
    ) async -> Result<PostProcessor.Success, PostProcessor.Failure> {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = agent.transformArguments(instructions: instructions, input: input,
                                                     effort: effort, model: model)
        // ⚠️ 工作目录必须是家目录，不能跟着 App 走：那几个裁上下文的开关
        // 已经关掉了项目设置的自动发现，但 cwd 仍然会进 git 状态之类的
        // 动态段落 —— 加工不需要知道你现在在哪个仓库里。
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // stdin 必须给一个自己的管道：非交互模式会读 stdin，继承一个终端
        // 或者悬空的 fd 时它会一直等下去。
        process.standardInput = Pipe()

        let started = CFAbsoluteTimeGetCurrent()
        do {
            try process.run()
        } catch {
            return .failure(.init(kind: .other,
                                  message: "起不了 \(agent.executable)：\(short(error))"))
        }

        // 超时看门狗：到点就杀掉。否则一次卡住的加工会把这条链上的段
        // 永远挂在「转写中」，而用户完全看不出发生了什么。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(agent.timeoutSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        var streamed = ""
        var final: CLIAgentEvent.Result?
        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                switch agent.parse(line: line) {
                case .textDelta(let delta):
                    streamed += delta
                    onDelta?(delta)
                case .result(let result):
                    final = result
                case .ignored:
                    break
                }
            }
        } catch {
            return .failure(.init(kind: .network,
                                  message: "读 \(agent.executable) 输出失败：\(short(error))"))
        }
        process.waitUntilExit()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let stderrText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard let final else {
            // 没有 result 行 = 被杀了或者崩了。stderr 是唯一线索。
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.init(
                kind: .network,
                message: detail.isEmpty ? "\(agent.executable) 没有返回结果（超时或被中断）"
                                        : String(detail.suffix(200))))
        }

        if final.isError {
            // 「没登录」是配置问题，不该被静默降级掩盖（A15 的同一条道理）。
            let isAuth = final.text.localizedCaseInsensitiveContains("login")
                || final.text.localizedCaseInsensitiveContains("api key")
                || final.errorKind == "api_error"
            return .failure(.init(kind: isAuth ? .auth : .serverError,
                                  message: "\(agent.executable)：\(final.text.prefix(160))"))
        }

        // 流式增量与 result 行应该一致；以 result 为准（它是完整的），
        // 但 result 空而增量不空时用增量 —— 有内容总比没有好。
        let complete = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = complete.isEmpty ? streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                                    : complete
        guard !text.isEmpty else {
            return .failure(.init(kind: .other, message: "\(agent.executable) 返回了空结果"))
        }
        return .success(.init(text: text, elapsed: elapsed, costUSD: final.costUSD))
    }

    private static func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
