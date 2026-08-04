import Foundation
import InkfallCore

/// 一次加工的执行层：真的发请求 / 真的 fork `claude`。
///
/// 「请求长什么样、响应怎么解、这一段该不该加工」全在 InkfallCore 里（有单测），
/// 这里只剩下三件测不动的事：发出去、把失败分类、把耗时和账单打进日志。
enum PostProcessor {

    /// 单请求 45 s（spec/01 常数表）。client 总超时 60 s。
    static let requestTimeout: TimeInterval = 45
    static let resourceTimeout: TimeInterval = 60

    struct Success: Sendable {
        var text: String
        var elapsed: TimeInterval
        /// Claude Code 那条路会报这一轮的花费；云端不报。
        var costUSD: Double?
    }

    struct Failure: Error, Sendable {
        var kind: CloudFailureKind
        var message: String
    }

    enum Route: Sendable {
        case cloud(provider: CloudProvider, model: String, key: String)
        /// 本机的命令行助手。`executablePath` 必须是绝对路径 —— App 从
        /// Finder 起来时 PATH 里没有 homebrew（见 `CLIAgentLocator`）。
        /// 不带 key：用的是那个工具自己的登录态。
        case cli(agent: CLIAgentKind, effort: String, model: String, executablePath: String)
    }

    struct Request: Sendable {
        var instructions: String
        var input: String
        var route: Route
    }

    /// 跑一次加工。
    ///
    /// `onDelta` 是流式增量（目前只有 Claude Code 那条路会喂）。它在后台线程上
    /// 被调用，调用方自己负责跳回主 actor。
    static func run(_ request: Request,
                    onDelta: (@Sendable (String) -> Void)? = nil) async -> Result<Success, Failure> {
        switch request.route {
        case .cloud(let provider, let model, let key):
            return await runCloud(provider: provider, model: model, key: key,
                                  instructions: request.instructions, input: request.input)
        case .cli(let agent, let effort, let model, let executablePath):
            // 具体是 claude / gemini / codex 由 `CLIAgentKind` 自己知道。
            return await CLIAgentRunner.runTransform(
                agent: agent, executablePath: executablePath,
                instructions: request.instructions, input: request.input,
                effort: effort, model: model, onDelta: onDelta)
        }
    }

    // MARK: - 云端

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }()

    private static func runCloud(provider: CloudProvider, model: String, key: String,
                                 instructions: String,
                                 input: String) async -> Result<Success, Failure> {
        guard let url = TextGenerationAPI.endpoint(provider: provider, model: model),
              let body = TextGenerationAPI.body(provider: provider, model: model,
                                                instructions: instructions, input: input) else {
            return .failure(.init(kind: .other, message: "请求构造失败"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in TextGenerationAPI.headers(provider: provider, key: key) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let started = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 无网 / DNS / TLS / 超时 / 拒连 —— 云端不可达，可以降级（A15）。
            return .failure(.init(kind: CloudFailureKind.sendError, message: short(error)))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let kind = CloudFailureKind.classify(status: status)
            let code = TextGenerationAPI.errorCode(in: data)
            return .failure(.init(kind: kind, message: message(status: status, code: code,
                                                               kind: kind, provider: provider)))
        }

        do {
            let text = try TextGenerationAPI.parse(provider: provider, data: data)
            return .success(.init(text: text,
                                  elapsed: CFAbsoluteTimeGetCurrent() - started,
                                  costUSD: nil))
        } catch {
            return .failure(.init(kind: .other, message: short(error)))
        }
    }

    /// 会员/鉴权错误要说成人话。一串英文 JSON 对着用户弹出来等于没说。
    private static func message(status: Int, code: String,
                                kind: CloudFailureKind, provider: CloudProvider) -> String {
        switch kind {
        case .auth: return "\(provider.label) 拒绝了这把 key（\(status)）—— 检查一下是不是过期或写错了"
        case .quota: return "\(provider.label) 的额度用完了（\(status)）"
        case .serverError: return "\(provider.label) 服务端故障（\(status)）"
        default:
            return code.isEmpty ? "\(provider.label) 返回 \(status)"
                                : "\(provider.label) 返回 \(status)：\(code)"
        }
    }

    private static func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
