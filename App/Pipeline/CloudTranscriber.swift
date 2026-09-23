import Foundation
import InkfallCore

/// 云端转写的执行层：真的把 multipart 发出去。
///
/// 「请求长什么样、响应怎么解」全在 InkfallCore 的 `TranscriptionAPI` 里（有单测），
/// 这里只剩下测不动的三件事：发出去、把失败分类（A15 的降级判据）、
/// 把耗时打进日志。
enum CloudTranscriber {

    struct Success: Sendable {
        var text: String
        /// 供应商报的语言（原始字符串）；只有 verbose_json 才有。
        var language: String?
        var elapsed: TimeInterval
    }

    struct Failure: Error, Sendable {
        var kind: CloudFailureKind
        var message: String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TranscriptionAPI.requestTimeout
        // 25 MB 的上传在慢网络上不止 45 s；总超时给到 90 s，
        // 与 Tauri 版的 client 总超时同一量级。
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    static func run(route: TranscriptionAPI.Route,
                    audio: RecordedAudio,
                    language: String?,
                    vocabulary: [String],
                    languageInstruction: String) async -> Result<Success, Failure> {
        let prepared: TranscriptionAPI.Prepared
        do {
            prepared = try TranscriptionAPI.prepare(route: route, audio: audio, language: language,
                                                    vocabulary: vocabulary,
                                                    languageInstruction: languageInstruction)
        } catch {
            return .failure(.init(kind: .other, message: short(error)))
        }

        var request = URLRequest(url: prepared.url)
        request.httpMethod = "POST"
        request.httpBody = prepared.body
        for (field, value) in prepared.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        Log.write("cloud-transcribe: 送 \(route.label)/\(route.model) "
                  + "lang=\(language ?? "auto") bytes=\(prepared.body.count)")
        let started = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 无网 / DNS / TLS / 超时 / 拒连 —— 云端不可达，可以降级（A15）。
            return .failure(.init(kind: CloudFailureKind.sendError, message: short(error)))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        Log.write(String(format: "cloud-transcribe: %@ %d %.2fs bytes=%d",
                         route.label, status, elapsed, data.count))

        guard (200...299).contains(status) else {
            let kind = CloudFailureKind.classify(status: status)
            let code = TextGenerationAPI.errorCode(in: data)
            return .failure(.init(kind: kind,
                                  message: message(status: status, code: code, kind: kind,
                                                   route: route, body: data)))
        }

        do {
            let parsed = try TranscriptionAPI.parse(route: route, data: data)
            return .success(.init(text: parsed.text, language: parsed.language, elapsed: elapsed))
        } catch {
            return .failure(.init(kind: .other, message: short(error)))
        }
    }

    /// 鉴权错误要说成人话。一串英文 JSON 对着用户弹出来等于没说。
    private static func message(status: Int, code: String, kind: CloudFailureKind,
                                route: TranscriptionAPI.Route, body: Data) -> String {
        switch kind {
        case .auth:
            return "\(route.label) 拒绝了这把 key（\(status)）—— 检查一下是不是过期或写错了"
        case .quota: return "\(route.label) 的额度用完了（\(status)）"
        case .serverError: return "\(route.label) 服务端故障（\(status)）"
        default:
            // 先要服务端那句给人看的话，再退到错误码，最后才截一段响应体 ——
            // 一坨多行 JSON 对着用户弹出来等于没说。
            let human = TextGenerationAPI.errorMessage(in: body)
            let detail = !human.isEmpty ? human : (!code.isEmpty ? code : truncated(body))
            return detail.isEmpty ? "\(route.errorLabel) 返回 \(status)"
                                  : "\(route.errorLabel) 返回 \(status)：\(detail)"
        }
    }

    private static func truncated(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= 120 ? text : String(text.prefix(120)) + "…"
    }

    private static func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
