import Foundation

/// 文本生成请求的**拼装与解析**，不碰网络。
///
/// 拆出来是为了能单测：真正发请求的那一层（`PostProcessor`）在 App 里，
/// 而「请求体长什么样、响应怎么解」是这一整条链上最容易写错、也最该被
/// 测住的部分。
///
/// OpenAI / Groq 走 **Responses API**（`/v1/responses`，`instructions` +
/// `input` 两段），与 Tauri 版一致 —— 不是 chat/completions。
/// Gemini 走 `:generateContent`，instructions 与 input 拼成一段文本。
public enum TextGenerationAPI {

    public enum Failure: LocalizedError, Equatable {
        case malformedResponse
        case emptyResult(CloudProvider)

        public var errorDescription: String? {
            switch self {
            case .malformedResponse: return "响应解析失败"
            case .emptyResult(let provider): return "\(provider.label) 返回了空结果"
            }
        }
    }

    /// 文本生成的温度。转写是 0.0，生成是 0.2（spec/05 §6.5）。
    public static let temperature = 0.2

    public static func endpoint(provider: CloudProvider, model: String) -> URL? {
        switch provider {
        case .openai:
            return URL(string: "https://api.openai.com/v1/responses")
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/responses")
        case .gemini:
            // 模型名进路径，必须转义 —— `/` 之类的字符会把路径拆断。
            let escaped = model.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? model
            return URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent")
        }
    }

    public static func headers(provider: CloudProvider, key: String) -> [String: String] {
        switch provider {
        case .openai, .groq:
            return ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]
        case .gemini:
            return ["x-goog-api-key": key, "Content-Type": "application/json"]
        }
    }

    public static func body(provider: CloudProvider, model: String,
                            instructions: String, input: String) -> Data? {
        let payload: [String: Any]
        switch provider {
        case .openai, .groq:
            var request: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "input": input,
            ]
            // Groq 上的 gpt-oss 系列默认会花很多 token 在思考上，而加工是个
            // 低难度高频的活儿 —— 明确压到 low（spec/05 §4）。
            if provider == .groq, model.contains("gpt-oss") {
                request["reasoning"] = ["effort": "low"]
            }
            payload = request
        case .gemini:
            payload = [
                "contents": [["parts": [["text": "\(instructions)\n\n\(input)"]]]],
                "generationConfig": ["temperature": temperature],
            ]
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public static func parse(provider: CloudProvider, data: Data) throws -> String {
        let text: String
        switch provider {
        case .openai, .groq:
            text = try parseResponsesAPI(data)
        case .gemini:
            text = try parseGemini(data)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyResult(provider) }
        return trimmed
    }

    /// 服务端返回的错误码（`{"error":"quotaExceeded"}` 这种），
    /// 用来把落音云的会员错误翻成人话。取不到就是空串。
    public static func errorCode(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let code = object["error"] as? String { return code }
        if let nested = object["error"] as? [String: Any] {
            return (nested["code"] as? String) ?? (nested["type"] as? String) ?? ""
        }
        return ""
    }

    // MARK: - 解析

    /// Responses API：`output[]` 里挑出 message 项，再挑出 output_text 段拼起来。
    /// ⚠️ `type` 缺失时**当作** message / output_text —— 老响应体不带这个字段，
    /// 严格判等会把正常结果整个丢掉。
    private static func parseResponsesAPI(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else {
            throw Failure.malformedResponse
        }
        var parts: [String] = []
        for item in output {
            let type = item["type"] as? String
            guard type == nil || type == "message" else { continue }
            for content in (item["content"] as? [[String: Any]]) ?? [] {
                let contentType = content["type"] as? String
                guard contentType == nil || contentType == "output_text" else { continue }
                if let text = content["text"] as? String { parts.append(text) }
            }
        }
        return parts.joined()
    }

    private static func parseGemini(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]] else {
            throw Failure.malformedResponse
        }
        var parts: [String] = []
        for candidate in candidates {
            guard let content = candidate["content"] as? [String: Any],
                  let items = content["parts"] as? [[String: Any]] else { continue }
            for item in items {
                if let text = item["text"] as? String { parts.append(text) }
            }
        }
        return parts.joined()
    }
}
