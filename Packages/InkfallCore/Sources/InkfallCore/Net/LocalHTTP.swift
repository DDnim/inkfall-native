import Foundation

/// 本地集成 API 的一次请求（spec/04 §3）。
public struct LocalHTTPRequest: Sendable, Equatable {
    public var method: String
    /// 去掉查询串的路径。
    public var path: String
    public var query: [String: String]
    /// header 名一律小写 —— HTTP header 名不区分大小写，而客户端写法五花八门。
    public var headers: [String: String]
    public var body: String

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: String = "") {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// `Authorization: Bearer <token>` 里的 token。
    public var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }
}

/// 手写的极简 HTTP/1.1 请求解析。
///
/// 为什么不引第三方 server 框架：这条服务只监听回环、只服务本机的 MCP 桥与
/// curl，请求形态是固定的五条路由。传输层用系统自带的 Network.framework
/// （`NWListener`），语法这一层几十行就够，而且**能被单测覆盖** ——
/// 一个跑在真实端口上的框架反而测不动。
public enum LocalHTTPParser {
    /// header 段上限。超了直接 431，不给对方把内存撑爆的机会。
    public static let maxHeaderBytes = 64 * 1024
    /// body 上限。
    public static let maxBodyBytes = 4 * 1024 * 1024

    public enum Outcome: Sendable, Equatable {
        /// 还没收全，继续读。
        case incomplete
        case request(LocalHTTPRequest)
        case failure(status: UInt16, message: String)
    }

    /// 解析已经收到的字节。
    ///
    /// - Returns: `.incomplete` 表示还要继续读；`.request` 时 `consumed` 是这次
    ///   请求占掉的字节数（keep-alive 时后面可能还跟着下一条）。
    public static func parse(_ data: Data) -> (outcome: Outcome, consumed: Int) {
        guard let separator = range(of: Array("\r\n\r\n".utf8), in: data)
            ?? range(of: Array("\n\n".utf8), in: data) else {
            if data.count > maxHeaderBytes {
                return (.failure(status: 431, message: "header too large"), data.count)
            }
            return (.incomplete, 0)
        }
        let headEnd = separator.lowerBound
        guard headEnd <= maxHeaderBytes else {
            return (.failure(status: 431, message: "header too large"), data.count)
        }
        // ⚠️ 按**字节**切行，不要按 Character。Swift 的 `Character` 是字形簇，
        // `"\r\n"` 是**一个**字符 —— 用 `split(separator: "\n")` 切一份 CRLF 的
        // header 一行都切不出来，整段 header 会被当成请求行（实测踩过）。
        let headBytes = [UInt8](data.subdata(in: data.startIndex..<headEnd))
        var lines = headBytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { chunk -> String in
                let trimmed = chunk.last == 0x0D ? chunk.dropLast() : chunk
                return String(decoding: trimmed, as: UTF8.self)
            }
        guard !lines.isEmpty else {
            return (.failure(status: 400, message: "empty request"), data.count)
        }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else {
            return (.failure(status: 400, message: "malformed request line"), data.count)
        }
        let method = requestLine[0].uppercased()
        let target = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declared = Int(headers["content-length"] ?? "") ?? 0
        guard declared <= maxBodyBytes else {
            return (.failure(status: 413, message: "body too large"), data.count)
        }
        let bodyStart = separator.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        guard available >= declared else { return (.incomplete, 0) }
        let bodyData = data.subdata(in: bodyStart..<(bodyStart + declared))
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        let (path, query) = splitTarget(target)
        let request = LocalHTTPRequest(method: method, path: path, query: query,
                                       headers: headers, body: body)
        return (.request(request), (bodyStart - data.startIndex) + declared)
    }

    /// `/debug/jarvis/match?text=你好&delay=2` → 路径 + 解码后的查询表。
    public static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[target.startIndex..<mark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = decode(parts[0]) else { continue }
            query[name] = parts.count > 1 ? (decode(parts[1]) ?? "") : ""
        }
        return (path, query)
    }

    /// 查询串里 `+` 是空格（表单编码），`%XX` 走百分号解码。
    private static func decode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? value.replacingOccurrences(of: "+", with: " ")
    }

    private static func range(of needle: [UInt8], in data: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        let bytes = [UInt8](data)
        let limit = bytes.count - needle.count
        var index = 0
        while index <= limit {
            if Array(bytes[index..<(index + needle.count)]) == needle {
                let start = data.startIndex + index
                return start..<(start + needle.count)
            }
            index += 1
        }
        return nil
    }
}

/// `/api/notes*` 的五条路由（spec/04 §3.1）。
public enum IntegrationRoute: Sendable, Equatable {
    case list
    case read(String)
    case create
    case update(String)
    case delete(String)

    public static func match(method: String, path: String) -> IntegrationRoute? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "api", segments[1] == "notes" else {
            return nil
        }
        let id = segments.count > 2 ? segments[2] : nil
        switch (method.uppercased(), id) {
        case ("GET", nil): return .list
        case ("GET", let id?): return .read(id)
        case ("POST", nil): return .create
        case ("PATCH", let id?): return .update(id)
        case ("DELETE", let id?): return .delete(id)
        default: return nil
        }
    }
}

public enum IntegrationToken {
    /// 等长逐字节 XOR 累加。本地回环，时序攻击不在威胁模型内，但仍然全长比较。
    public static func matches(_ token: String, _ candidate: String) -> Bool {
        let a = Array(token.utf8)
        let b = Array(candidate.utf8)
        guard !a.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// 两个 UUIDv4 拼成的 64 位十六进制串（spec/03 §10）。
    public static func generate() -> String {
        let strip = { (uuid: UUID) in
            uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return strip(UUID()) + strip(UUID())
    }
}
