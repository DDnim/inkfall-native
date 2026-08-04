import Foundation
import InkfallCore

/// 后台的 Claude Code 助手。
///
/// 一句话 = `claude -p` 的一轮。**同一个关键词的后续每一句都 `--resume`
/// 接回同一场会话**，所以它记得住上下文 —— 这正是「助手」和「每次从零开始的
/// 一次性命令」的区别。
///
/// 跑在 **tmux** 里而不是裸后台进程：
/// - 它活得比这次询问长，也活得比 App 长
/// - `tmux attach -t inkfall` 能看到整段对话（每一轮一个窗口，跑完不销毁）
/// - 出了问题有现场可看，而不是只剩一行日志
///
/// 没装 tmux 时回落成一个脱管的子进程 —— 功能照常，只是没法 attach 上去看。
@MainActor
final class ClaudeCodeAgent {

    struct Answer {
        var text: String
        var isError: Bool
        var durationMs: Int?
        var costUSD: Double?
        /// 这一轮是接着上一轮说的（不是新开一场）。
        var resumed: Bool
    }

    /// 每个关键词一场会话。
    private struct Conversation {
        var sessionID: String
        var turns: Int
    }

    private var conversations: [String: Conversation] = [:]
    /// 同一时刻只允许一轮在飞。第二句话来的时候上一句还没答完是常事，
    /// 并发发进同一个 session id 只会把会话文件写坏。
    private(set) var busyKeyword: String?

    private var pollTimer: Timer?

    // MARK: - 可执行文件

    /// 查找逻辑在 `CLIAgentLocator`（贾维斯和加工都要找同一个 `claude`，
    /// 而 App 从 Finder 起来时 PATH 是空的 —— 这件事只该实现一次）。
    static var claudePath: String? { CLIAgentLocator.path(for: .claudeCode) }
    static var tmuxPath: String? { CLIAgentLocator.locate("tmux") }

    /// 装没装齐。设置页拿它给一行明确的话，而不是等用户说完才失败。
    static var readiness: String {
        switch (claudePath, tmuxPath) {
        case (nil, _): return "没找到 claude 命令 —— 先装 Claude Code"
        case (_, nil): return "没装 tmux，会回落成后台进程（brew install tmux 可以 attach 上去看）"
        default: return "就绪"
        }
    }

    var hasClaude: Bool { Self.claudePath != nil }

    // MARK: - 会话

    func hasConversation(keyword: String) -> Bool { conversations[keyword] != nil }

    func sessionID(keyword: String) -> String? { conversations[keyword]?.sessionID }

    /// 忘掉这场对话，下一句重新开一场。
    func reset(keyword: String? = nil) {
        if let keyword {
            conversations.removeValue(forKey: keyword)
        } else {
            conversations.removeAll()
        }
    }

    // MARK: - 一轮

    /// 问一句。
    ///
    /// - Parameter completion: 主 actor 上回调。超时/起不来也一定会回调 ——
    ///   静默失败会让用户对着一个永远「思考中」的刘海等下去。
    func ask(_ prompt: String, command: VoiceCommand,
             completion: @escaping @MainActor (Result<Answer, Error>) -> Void) {
        guard let claude = Self.claudePath else {
            completion(.failure(Failure.claudeMissing))
            return
        }
        if let busy = busyKeyword {
            completion(.failure(Failure.busy(busy)))
            return
        }

        let keyword = command.keyword
        var conversation = conversations[keyword]
            ?? Conversation(sessionID: UUID().uuidString.lowercased(), turns: 0)
        let resuming = conversation.turns > 0
        conversation.turns += 1
        conversations[keyword] = conversation

        let stamp = "\(UInt64(Date().timeIntervalSince1970 * 1000))"
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-claude-\(stamp)")
        let turn = ClaudeCodeTurn(
            sessionID: conversation.sessionID, prompt: prompt, resuming: resuming,
            skipPermissions: command.skipPermissions,
            // 不放行的话「查一下今天的股价」这类问题永远答不了 ——
            // `-p` 弹不出确认框，WebFetch 直接被拒，模型只会回一句「没拿到权限」。
            allowedTools: command.allowWebTools ? ClaudeCode.webTools : [],
            workingDirectory: command.workingDirectory,
            outputPath: base.path + ".json", errorPath: base.path + ".err",
            statusPath: base.path + ".status", claudePath: claude)

        let scriptPath = base.path + ".command"
        do {
            try ClaudeCode.script(for: turn).write(toFile: scriptPath, atomically: true,
                                                   encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: scriptPath)
        } catch {
            completion(.failure(error))
            return
        }

        do {
            try launch(scriptPath: scriptPath, keyword: keyword, turn: conversation.turns)
        } catch {
            completion(.failure(error))
            return
        }

        busyKeyword = keyword
        Log.write("claude: 第 \(conversation.turns) 轮"
            + "（\(resuming ? "接着上一轮" : "新会话 \(conversation.sessionID)")）"
            + " \(prompt.prefix(40))")
        poll(turn: turn, resumed: resuming, deadline: Date()
            .addingTimeInterval(ClaudeCode.turnTimeoutSeconds), completion: completion)
    }

    /// 挂进 tmux；没有 tmux 就直接脱管跑。
    ///
    /// 一轮 = 一个窗口，窗口直接跑脚本，跑完靠 `remain-on-exit` 留下 ——
    /// 那些留下的 pane 就是这场对话的存档，`tmux attach -t inkfall` 一路翻回去
    /// 能看到每一轮问了什么、答了什么。
    private func launch(scriptPath: String, keyword: String, turn: Int) throws {
        let window = ClaudeCode.windowName(keyword: keyword, turn: turn)
        guard let tmux = Self.tmuxPath else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptPath]
            try process.run()
            Log.write("claude: 没有 tmux，脱管跑（attach 不上去）")
            return
        }

        let hasSession = run(tmux, ["has-session", "-t", ClaudeCode.tmuxSession]) == 0
        let create = hasSession
            ? ClaudeCode.tmuxCreateWindow(window: window, scriptPath: scriptPath)
            : ClaudeCode.tmuxCreateSession(window: window, scriptPath: scriptPath)
        guard run(tmux, create) == 0 else { throw Failure.tmuxFailed }
        // 紧接着设 —— 抢在脚本跑完之前。抢不上也只是丢一份存档，
        // 回答本身是从文件里读的，不受影响。
        _ = run(tmux, ClaudeCode.tmuxRemainOnExit(window: window))
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 等这一轮结束。
    ///
    /// 判据是**退出码文件**而不是 JSON：claude 崩掉时根本不会有 JSON，
    /// 只等 JSON 会一路等到超时。
    private func poll(turn: ClaudeCodeTurn, resumed: Bool, deadline: Date,
                      completion: @escaping @MainActor (Result<Answer, Error>) -> Void) {
        pollTimer?.invalidate()
        // ⚠️ 不要在 Task 里碰闭包参数里那个 `timer` —— 把它送进另一个隔离域
        // 过不了 Swift 6 的并发检查。停表统一走 `self.pollTimer`。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                if FileManager.default.fileExists(atPath: turn.statusPath) {
                    self.stopPolling()
                    self.finish(turn: turn, resumed: resumed, completion: completion)
                    return
                }
                guard Date() >= deadline else { return }
                self.stopPolling()
                // 超时不重置会话：那一轮多半还在跑，下一句仍然该接回同一场。
                completion(.failure(Failure.timedOut))
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        busyKeyword = nil
    }

    private func finish(turn: ClaudeCodeTurn, resumed: Bool,
                        completion: @MainActor (Result<Answer, Error>) -> Void) {
        let status = (try? String(contentsOfFile: turn.statusPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let json = (try? String(contentsOfFile: turn.outputPath, encoding: .utf8)) ?? ""
        defer {
            for path in [turn.statusPath, turn.outputPath, turn.errorPath] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        guard let reply = ClaudeCode.parse(json) else {
            let stderr = (try? String(contentsOfFile: turn.errorPath, encoding: .utf8)) ?? ""
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("claude: 退出码 \(status) 无可读回答 \(detail.prefix(200))")
            // 第一轮就没成，那个 session id 根本没落在盘上 —— 留着它会让
            // 下一句 `--resume` 到一个不存在的会话，然后每一句都失败。
            if !resumed { reset(keyword: nil) }
            completion(.failure(Failure.noReply(detail.isEmpty ? "退出码 \(status)"
                                                              : String(detail.prefix(120)))))
            return
        }
        Log.write("claude: 第一句回答 \(reply.text.prefix(80))"
            + "（\(reply.durationMs.map { "\($0)ms" } ?? "?")"
            + "，$\(reply.costUSD.map { String(format: "%.4f", $0) } ?? "?")）")
        completion(.success(Answer(text: reply.text, isError: reply.isError,
                                   durationMs: reply.durationMs, costUSD: reply.costUSD,
                                   resumed: resumed)))
    }

    enum Failure: LocalizedError {
        case claudeMissing
        case tmuxFailed
        case timedOut
        case busy(String)
        case noReply(String)

        var errorDescription: String? {
            switch self {
            case .claudeMissing: return "没找到 claude 命令"
            case .tmuxFailed: return "tmux 起不来"
            case .timedOut: return "克劳德超时了（\(Int(ClaudeCode.turnTimeoutSeconds))s）"
            case .busy(let keyword): return "「\(keyword)」还在想上一句"
            case .noReply(let detail): return "克劳德没有回答：\(detail)"
            }
        }
    }

    // MARK: - 自测取证

    var debugSnapshot: String {
        let sessions = conversations.map { "\($0.key)→\($0.value.sessionID.prefix(8))"
            + "×\($0.value.turns)" }.joined(separator: " ")
        return "claude=\(Self.claudePath ?? "无") tmux=\(Self.tmuxPath ?? "无") "
            + "会话[\(sessions)] 在飞=\(busyKeyword ?? "无")"
    }
}
