import Foundation

/// `multipart/form-data` 请求体，**自己拼**（spec/05 §1.2，与 Tauri 版字节级一致）。
///
/// 不用 URLSession 的 upload 表单封装：那一层对文件名、Content-Type 与段间
/// 换行的处理随系统版本变过，而 Groq 对边界与 CRLF 很挑 —— 一次「多了一个
/// `\n`」就是整场 400。自己拼的每个字节都能被单测钉住。
public struct MultipartForm: Sendable, Equatable {

    public static let boundaryPrefix = "InkfallBoundary"

    public let boundary: String
    private var data = Data()

    /// - Parameter boundary: 默认 `InkfallBoundary<uuid>`；测试时传固定值。
    public init(boundary: String = boundaryPrefix + UUID().uuidString) {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func addFields(_ fields: [(String, String)]) {
        for (name, value) in fields { addField(name, value) }
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data file: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(file)
        append("\r\n")
    }

    /// 收尾边界 + 整个请求体。
    public func build() -> Data {
        var body = data
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// 文件名进 `Content-Disposition`：路径分隔符与冒号替掉，空的给默认名。
    public static func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "inkfall-recording.wav" }
        return String(trimmed.map { character in
            switch character {
            case "/", "\\", ":", "\0": return "_"
            default: return character
            }
        })
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}
