import Foundation
import InkfallCore

/// 试做：每段转写完顺手问 Jev「这是不是在叫助手」，只记日志 + 在刘海上提一句。
///
/// 减法版没有助手，所以**绝不改变粘贴行为**：Jev 不通、超时、没 key 都当没问过。
/// key 取 `TYPESAFE_API_KEY` 或 `~/.config/typesafe/api_key`（与 experiments/jev 相同），
/// 两处都没有就整条关掉 —— 不配 key 的用户不该多出一次网络往返。
final class AssistantIntentProbe: @unchecked Sendable {

    struct Result: Sendable {
        let p: Double
        let verdict: AssistantIntentAPI.Verdict
        let elapsedMs: Int
    }

    /// 等 Jev 最多这么久。p90 226ms，给到 0.8 秒；超了就不等，文字照常粘。
    static let timeout: TimeInterval = 0.8

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    private lazy var key: String? = {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typesafe/api_key")
        let raw = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }()

    var isEnabled: Bool { key != nil }

    /// 失败一律回 nil（原因写日志）。
    func judge(text: String, appName: String, bundleID: String?) async -> Result? {
        guard let key else { return nil }
        guard let body = AssistantIntentAPI.body(appName: appName, bundleID: bundleID, text: text) else { return nil }
        var request = URLRequest(url: AssistantIntentAPI.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in AssistantIntentAPI.headers(key: key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.write("intent: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                return nil
            }
            let p = try AssistantIntentAPI.parse(data)
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            return Result(p: p, verdict: .decide(p), elapsedMs: ms)
        } catch {
            Log.write("intent: 失败 \(error.localizedDescription)")
            return nil
        }
    }
}
